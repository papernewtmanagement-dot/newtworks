 import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";

import { useTabParam } from "../lib/routing.jsx";
// ============================================================
// Newtworks MARKETING MODULE v1.0
// Newtworks — State Farm Agent Edition
//
// Phase 1 tabs (built 2026-07-10):
//   Overview    — KPIs, envelope status, alerts
//   Sources     — Lead source table w/ CPA, close ratio, ROI
//   Spend       — GL marketing spend by month vs envelope
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

// ─── EverQuote Deep Dive Tab ──────────────────────────────────
function useEverquoteData() {
  const [state, setState] = useState({ loading: true, reviews: [], metrics: [], error: null });
  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        const [rRes, mRes] = await Promise.all([
          supabase.from("everquote_reviews")
            .select("id, review_date, current_period_start, current_period_end, previous_period_start, previous_period_end, is_ytd, file_name")
            .eq("agency_id", AGENCY_ID)
            .order("review_date", { ascending: false })
            .order("is_ytd", { ascending: true }),
          supabase.from("everquote_review_metrics")
            .select("*")
            .order("sort_order", { ascending: true, nullsFirst: false }),
        ]);
        if (cancelled) return;
        const reviews = Array.isArray(rRes?.data) ? rRes.data : [];
        const metrics = Array.isArray(mRes?.data) ? mRes.data : [];
        setState({ loading: false, reviews, metrics, error: null });
      } catch (err) {
        if (!cancelled) setState({ loading: false, reviews: [], metrics: [], error: err?.message || String(err) });
      }
    }
    load();
    return () => { cancelled = true; };
  }, []);
  return state;
}

// Sum leads + binds across a metrics slice. Also compute weighted CPB.
function eqAggregate(rows) {
  let leads = 0, binds = 0, costTotal = 0, quotes = 0;
  (rows || []).forEach(r => {
    const l = Number(r?.leads) || 0;
    const b = Number(r?.binds) || 0;
    leads += l;
    binds += b;
    if (Number(r?.cpb) > 0 && b > 0) costTotal += Number(r.cpb) * b;
    if (Number(r?.quotes) > 0) quotes += Number(r.quotes);
  });
  const bindPct = leads > 0 ? binds / leads : null;
  const cpb = binds > 0 && costTotal > 0 ? costTotal / binds : null;
  return { leads, binds, bindPct, cpb, costTotal, quotes };
}

// Preferred dimension for headline totals — lead_type is complete + non-overlapping.
function eqHeadline(metrics, scope) {
  const scoped = (metrics || []).filter(m => m.period_scope === scope);
  // Try lead_type first, then campaign, then age_bucket
  for (const dim of ["lead_type", "campaign", "age_bucket"]) {
    const rows = scoped.filter(m => m.dimension === dim);
    if (rows.length > 0) {
      const agg = eqAggregate(rows);
      if (agg.leads > 0) return { ...agg, source_dim: dim };
    }
  }
  return { leads: 0, binds: 0, bindPct: null, cpb: null, costTotal: 0, quotes: 0, source_dim: null };
}

// Dimension label + friendly title
const EQ_DIMS = [
  { id: "campaign",         label: "Campaign" },
  { id: "previous_insurer", label: "Previous Insurer" },
  { id: "county",           label: "County" },
  { id: "age_bucket",       label: "Age Bucket" },
  { id: "day_of_week",      label: "Day of Week" },
  { id: "lead_type",        label: "Lead Type" },
  { id: "state",            label: "State" },
  { id: "monthly_trend",    label: "Monthly Trend" },
];

// Generate action recommendations from current metrics.
function generateEqRecs(currentByDim, prevByDim, headline, prevHeadline) {
  const recs = [];

  // Trend vs previous
  if (headline.bindPct != null && prevHeadline.bindPct != null) {
    const delta = headline.bindPct - prevHeadline.bindPct;
    if (Math.abs(delta) >= 0.005) {
      recs.push({
        tone: delta > 0 ? "good" : "warn",
        text: `Bind % ${delta > 0 ? "improved" : "declined"} ${(Math.abs(delta) * 100).toFixed(2)} pts vs previous period (${(headline.bindPct * 100).toFixed(2)}% vs ${(prevHeadline.bindPct * 100).toFixed(2)}%).`,
      });
    }
  }

  // Zero-bind previous insurers with ≥5 leads
  const pi = (currentByDim.previous_insurer || []).filter(r => (Number(r.leads) || 0) >= 5 && (Number(r.binds) || 0) === 0);
  pi.forEach(r => recs.push({
    tone: "bad",
    text: `${r.dimension_value}: ${r.leads} leads / 0 binds this period. Deprioritize or exclude in targeting.`,
  }));

  // Best-performing previous insurer (bind_pct ≥ agency avg and ≥5 leads)
  const piBest = (currentByDim.previous_insurer || [])
    .filter(r => (Number(r.leads) || 0) >= 5 && Number(r.bind_pct) >= 7)
    .sort((a, b) => Number(b.bind_pct) - Number(a.bind_pct))
    .slice(0, 2);
  piBest.forEach(r => recs.push({
    tone: "good",
    text: `${r.dimension_value} shoppers converting at ${Number(r.bind_pct).toFixed(1)}% (${r.binds}/${r.leads}). Push targeting.`,
  }));

  // Zero-bind day of week with ≥10 leads
  const dow = (currentByDim.day_of_week || []).filter(r => (Number(r.leads) || 0) >= 10 && (Number(r.binds) || 0) === 0);
  dow.forEach(r => recs.push({
    tone: "bad",
    text: `${r.dimension_value}: ${r.leads} leads / 0 binds. Reduce or pause daily cap.`,
  }));

  // County outperformance ratio (top vs bottom, both ≥5 leads)
  const counties = (currentByDim.county || [])
    .filter(r => (Number(r.leads) || 0) >= 5)
    .sort((a, b) => Number(b.bind_pct) - Number(a.bind_pct));
  if (counties.length >= 2) {
    const top = counties[0];
    const bot = counties[counties.length - 1];
    if (Number(top.bind_pct) > 0 && Number(bot.bind_pct) === 0) {
      recs.push({
        tone: "good",
        text: `${top.dimension_value} converting at ${Number(top.bind_pct).toFixed(1)}% while ${bot.dimension_value} has 0 binds on ${bot.leads} leads. Rebalance bid weights.`,
      });
    }
  }

  // Age bucket CPB spread
  const ages = (currentByDim.age_bucket || []).filter(r => Number(r.cpb) > 0);
  if (ages.length >= 2) {
    const worst = [...ages].sort((a, b) => Number(b.cpb) - Number(a.cpb))[0];
    const best = [...ages].sort((a, b) => Number(a.cpb) - Number(b.cpb))[0];
    if (Number(worst.cpb) >= Number(best.cpb) * 2) {
      recs.push({
        tone: "warn",
        text: `Age ${worst.dimension_value}: ${Number(worst.cpb).toFixed(0)}/HH CPB vs ${best.dimension_value}: ${Number(best.cpb).toFixed(0)}/HH. Rebalance toward the cheaper bucket.`,
      });
    }
  }

  // Best campaign
  const campaigns = (currentByDim.campaign || []).filter(r => (Number(r.binds) || 0) > 0);
  if (campaigns.length >= 1) {
    const topCamp = [...campaigns].sort((a, b) => Number(b.bind_pct) - Number(a.bind_pct))[0];
    recs.push({
      tone: "good",
      text: `Best campaign: ${topCamp.dimension_value} — ${topCamp.binds} binds on ${topCamp.leads} leads (${Number(topCamp.bind_pct).toFixed(2)}%, CPB ${Number(topCamp.cpb || 0).toFixed(0)}).`,
    });
  }

  // Zero-bind campaigns with ≥5 leads
  const zeroCamps = (currentByDim.campaign || []).filter(r => (Number(r.leads) || 0) >= 5 && (Number(r.binds) || 0) === 0);
  zeroCamps.forEach(r => recs.push({
    tone: "bad",
    text: `Campaign "${r.dimension_value}" underperforming: ${r.leads} leads / 0 binds. Investigate or pause.`,
  }));

  return recs;
}

function DimBreakdown({ title, rows, prevRows, vp }) {
  if (!rows || rows.length === 0) return null;

  // Sort by leads desc
  const sorted = [...rows].sort((a, b) => (Number(b.leads) || 0) - (Number(a.leads) || 0));
  // Index previous by dimension_value for delta computation
  const prevMap = {};
  (prevRows || []).forEach(r => { prevMap[r.dimension_value] = r; });

  return (
    <div style={{ marginTop: 14 }}>
      <div style={{ fontSize: 12, fontWeight: 700, color: T.slate900, marginBottom: 6, textTransform: "uppercase", letterSpacing: "0.03em" }}>
        {title}
      </div>
      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 8 }}>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12, minWidth: 460 }}>
          <thead>
            <tr style={{ background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
              <th style={thStyle}>Value</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Leads</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Binds</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Bind %</th>
              <th style={{ ...thStyle, textAlign: "right" }}>CPB</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Δ vs prev</th>
            </tr>
          </thead>
          <tbody>
            {sorted.map(r => {
              const leads = Number(r.leads) || 0;
              const binds = Number(r.binds) || 0;
              const bindPct = Number(r.bind_pct);
              const cpb = Number(r.cpb);
              const prev = prevMap[r.dimension_value];
              const prevBindPct = prev ? Number(prev.bind_pct) : null;
              const delta = (Number.isFinite(bindPct) && Number.isFinite(prevBindPct)) ? bindPct - prevBindPct : null;
              const isZero = leads >= 5 && binds === 0;
              return (
                <tr key={`${r.dimension}-${r.dimension_value}`} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                  <td style={{ ...tdStyle, fontWeight: 500, color: isZero ? "#991B1B" : T.slate900 }}>
                    {r.dimension_value}
                  </td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{leads}</td>
                  <td style={{ ...tdStyle, textAlign: "right", fontWeight: binds > 0 ? 600 : 400 }}>{binds}</td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{Number.isFinite(bindPct) ? `${bindPct.toFixed(2)}%` : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{Number.isFinite(cpb) && cpb > 0 ? `$${Math.round(cpb)}` : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right", color: delta == null ? T.slate400 : (delta >= 0 ? "#065F46" : "#991B1B") }}>
                    {delta == null ? "—" : `${delta >= 0 ? "+" : ""}${delta.toFixed(2)} pts`}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function EverquoteTab() {
  const vp = useViewport();
  const { loading, reviews, metrics, error } = useEverquoteData();
  // URL-persisted so refresh keeps the same review open.
  const [selectedReviewId, setSelectedReviewId] = useTabParam("review", null);

  // Default selection = latest non-YTD review
  useEffect(() => {
    if (!selectedReviewId && reviews.length > 0) {
      const nonYtd = reviews.find(r => !r.is_ytd);
      setSelectedReviewId((nonYtd || reviews[0]).id);
    }
  }, [reviews, selectedReviewId]);

  if (loading) return <div style={{ padding: 40, textAlign: "center", color: T.slate500, fontSize: 13 }}>Loading…</div>;
  if (error) return <div style={{ padding: 20, color: "#991B1B", fontSize: 13 }}>Error: {error}</div>;
  if (reviews.length === 0) {
    return (
      <div style={{ padding: 24, textAlign: "center", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, color: T.slate500, fontSize: 13 }}>
        No EverQuote reviews ingested yet.
      </div>
    );
  }

  const selectedReview = reviews.find(r => r.id === selectedReviewId) || reviews[0];
  const reviewMetrics = metrics.filter(m => m.review_id === selectedReview.id);
  const headline = eqHeadline(reviewMetrics, "current");
  const prevHeadline = eqHeadline(reviewMetrics, "previous");

  // Group current + previous by dimension
  const currentByDim = {};
  const prevByDim = {};
  reviewMetrics.forEach(m => {
    const target = m.period_scope === "current" ? currentByDim : m.period_scope === "previous" ? prevByDim : null;
    if (!target) return;
    if (!target[m.dimension]) target[m.dimension] = [];
    target[m.dimension].push(m);
  });

  const recs = generateEqRecs(currentByDim, prevByDim, headline, prevHeadline);
  const kpiCols = vp.isPhone ? "repeat(auto-fit, minmax(140px, 1fr))" : "repeat(auto-fit, minmax(160px, 1fr))";

  return (
    <div>
      {/* Review selector */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6, flexWrap: "wrap" }}>
        <div style={{ fontSize: 12, color: T.slate500 }}>Review:</div>
        <select
          value={selectedReview.id}
          onChange={e => setSelectedReviewId(e.target.value)}
          style={{
            padding: "6px 10px", fontSize: 12, fontWeight: 600, color: T.slate700,
            background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 7, cursor: "pointer",
          }}
        >
          {reviews.map(r => {
            const label = r.is_ytd
              ? `YTD ${r.current_period_start} → ${r.current_period_end}`
              : `${r.current_period_start} → ${r.current_period_end}`;
            return <option key={r.id} value={r.id}>{label}</option>;
          })}
        </select>
        <div style={{ fontSize: 11, color: T.slate500 }}>
          Ingested {selectedReview.review_date}
        </div>
      </div>

      <SectionTitle>Current period totals</SectionTitle>
      <div style={{ display: "grid", gridTemplateColumns: kpiCols, gap: 10 }}>
        <KpiCard
          label="Leads"
          value={headline.leads > 0 ? fmtInt(headline.leads) : "—"}
          sub={prevHeadline.leads > 0 ? `Prev: ${fmtInt(prevHeadline.leads)}` : ""}
        />
        <KpiCard
          label="Binds"
          value={headline.binds > 0 ? fmtInt(headline.binds) : "0"}
          sub={prevHeadline.binds > 0 ? `Prev: ${fmtInt(prevHeadline.binds)}` : ""}
        />
        <KpiCard
          label="Bind %"
          value={headline.bindPct != null ? `${(headline.bindPct * 100).toFixed(2)}%` : "—"}
          sub={prevHeadline.bindPct != null ? `Prev: ${(prevHeadline.bindPct * 100).toFixed(2)}%` : ""}
          tone={
            headline.bindPct != null && prevHeadline.bindPct != null
              ? (headline.bindPct >= prevHeadline.bindPct ? "good" : "warn")
              : "neutral"
          }
        />
        <KpiCard
          label="CPB"
          value={headline.cpb != null ? `$${Math.round(headline.cpb)}` : "—"}
          sub={prevHeadline.cpb != null ? `Prev: $${Math.round(prevHeadline.cpb)}` : ""}
          tone={
            headline.cpb != null && prevHeadline.cpb != null
              ? (headline.cpb <= prevHeadline.cpb ? "good" : "warn")
              : "neutral"
          }
        />
      </div>
      <div style={{ fontSize: 11, color: T.slate500, marginTop: 6 }}>
        Totals rolled up from <strong>{headline.source_dim || "n/a"}</strong> dimension (deck's non-overlapping segmentation).
      </div>

      <SectionTitle>Recommendations</SectionTitle>
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        {recs.length === 0 && (
          <div style={{ fontSize: 12, color: T.slate500, padding: "8px 4px" }}>No actionable patterns detected in this period.</div>
        )}
        {recs.map((r, i) => (
          <AlertPill key={i} tone={r.tone === "good" ? "info" : r.tone}>{r.text}</AlertPill>
        ))}
      </div>

      <SectionTitle>Dimension breakdowns</SectionTitle>
      <div>
        {EQ_DIMS.map(d => (
          <DimBreakdown
            key={d.id}
            title={d.label}
            rows={currentByDim[d.id]}
            prevRows={prevByDim[d.id]}
            vp={vp}
          />
        ))}
      </div>

      <div style={{ marginTop: 18, fontSize: 11, color: T.slate500, lineHeight: 1.6 }}>
        Source: monthly EverQuote BC Review decks, OCR-ingested to <code style={{ background: T.slate100, padding: "1px 4px", borderRadius: 3 }}>everquote_review_metrics</code>. Deltas shown against the deck's own previous-period columns (not YTD).
      </div>
    </div>
  );
}


// ─── Referrals & Reviews Tab ──────────────────────────────────
function useTeamRoster() {
  const [team, setTeam] = useState([]);
  useEffect(() => {
    let cancelled = false;
    async function load() {
      const { data } = await supabase.from("team")
        .select("id, first_name, last_name, is_admin_backoffice, is_active")
        .eq("agency_id", AGENCY_ID)
        .neq("is_admin_backoffice", true)
        .eq("is_active", true)
        .order("first_name");
      if (!cancelled) setTeam(Array.isArray(data) ? data : []);
    }
    load();
    return () => { cancelled = true; };
  }, []);
  return team;
}

function useRefRevData() {
  const [state, setState] = useState({ loading: true, referrals: [], reviews: [], error: null, reloadCount: 0 });
  const reload = () => setState(s => ({ ...s, reloadCount: s.reloadCount + 1 }));
  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        setState(s => ({ ...s, loading: true, error: null }));
        const [refRes, revRes] = await Promise.all([
          supabase.from("referrals").select("*").eq("agency_id", AGENCY_ID).order("referred_at", { ascending: false }),
          supabase.from("gbp_reviews").select("*").eq("agency_id", AGENCY_ID).order("review_date", { ascending: false }),
        ]);
        if (cancelled) return;
        setState(s => ({
          ...s,
          loading: false,
          referrals: Array.isArray(refRes?.data) ? refRes.data : [],
          reviews: Array.isArray(revRes?.data) ? revRes.data : [],
        }));
      } catch (err) {
        if (!cancelled) setState(s => ({ ...s, loading: false, error: err?.message || String(err) }));
      }
    }
    load();
    return () => { cancelled = true; };
  }, [state.reloadCount]);
  return { ...state, reload };
}

const REFERRAL_STATUSES = [
  { id: "received",  label: "Received",  color: T.slate500 },
  { id: "contacted", label: "Contacted", color: T.slate700 },
  { id: "quoted",    label: "Quoted",    color: T.gold },
  { id: "sold",      label: "Sold",      color: T.green },
  { id: "dead",      label: "Dead",      color: T.red },
];

function nameFor(id, team) {
  const t = team.find(x => x?.id === id);
  return t ? `${t.first_name} ${t.last_name || ""}`.trim() : "—";
}

// ─── Referrals sub-view ───────────────────────────────────────
function ReferralsView({ rows, team, onReload }) {
  const vp = useViewport();
  const [showAdd, setShowAdd] = useState(false);
  const [statusFilter, setStatusFilter] = useState("all");
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState(null);
  const [form, setForm] = useState({
    referred_by_name: "",
    referred_household_name: "",
    referral_source: "customer",
    assigned_to: "",
    referred_at: new Date().toISOString().slice(0, 10),
    notes: "",
  });

  const kpiCols = vp.isPhone ? "repeat(auto-fit, minmax(120px, 1fr))" : "repeat(auto-fit, minmax(140px, 1fr))";

  const filtered = rows.filter(r => statusFilter === "all" ? true : r.status === statusFilter);
  const yr = String(new Date().getFullYear());
  const ytdRows = rows.filter(r => r.referred_at?.slice(0, 4) === yr);
  const totalYtd = ytdRows.length;
  const quotedYtd = ytdRows.filter(r => r.quoted_at || r.status === "quoted" || r.status === "sold").length;
  const soldYtd = ytdRows.filter(r => r.status === "sold").length;
  const conversion = quotedYtd > 0 ? (soldYtd / quotedYtd) : null;
  const totalPremium = ytdRows.reduce((sum, r) => sum + (Number(r.bind_premium) || 0), 0);
  const avgPremium = soldYtd > 0 ? totalPremium / soldYtd : null;

  const handleAdd = async () => {
    if (!form.referred_by_name.trim() || !form.referred_household_name.trim()) {
      setErr("Referred by + household name required.");
      return;
    }
    setSaving(true);
    setErr(null);
    try {
      const payload = {
        agency_id: AGENCY_ID,
        referred_by_name: form.referred_by_name.trim(),
        referred_household_name: form.referred_household_name.trim(),
        referral_source: form.referral_source || null,
        assigned_to: form.assigned_to || null,
        referred_at: form.referred_at || null,
        notes: form.notes || null,
        status: "received",
      };
      const { error } = await supabase.from("referrals").insert(payload);
      if (error) throw error;
      setShowAdd(false);
      setForm({
        referred_by_name: "",
        referred_household_name: "",
        referral_source: "customer",
        assigned_to: "",
        referred_at: new Date().toISOString().slice(0, 10),
        notes: "",
      });
      onReload();
    } catch (e) {
      setErr(e?.message || String(e));
    } finally {
      setSaving(false);
    }
  };

  const advanceStatus = async (row) => {
    const idx = REFERRAL_STATUSES.findIndex(s => s.id === row.status);
    const next = REFERRAL_STATUSES[(idx + 1) % REFERRAL_STATUSES.length];
    const patch = { status: next.id };
    if (next.id === "quoted" && !row.quoted_at) patch.quoted_at = new Date().toISOString().slice(0, 10);
    if (next.id === "sold" && !row.sold_at) patch.sold_at = new Date().toISOString().slice(0, 10);
    await supabase.from("referrals").update(patch).eq("id", row.id);
    onReload();
  };

  return (
    <div>
      <SectionTitle>Referrals YTD</SectionTitle>
      <div style={{ display: "grid", gridTemplateColumns: kpiCols, gap: 10 }}>
        <KpiCard label="Total Referrals" value={fmtInt(totalYtd)} sub={`YTD ${yr}`} />
        <KpiCard label="Quoted" value={fmtInt(quotedYtd)} sub={totalYtd > 0 ? `${((quotedYtd / totalYtd) * 100).toFixed(0)}% of total` : ""} />
        <KpiCard label="Sold" value={fmtInt(soldYtd)} tone={soldYtd > 0 ? "good" : "neutral"} sub={conversion != null ? `${(conversion * 100).toFixed(0)}% close` : ""} />
        <KpiCard label="Premium Bound" value={fmtMoney(totalPremium)} sub={avgPremium ? `${fmtMoney(avgPremium)}/HH avg` : ""} />
      </div>

      <div style={{ display: "flex", gap: 6, marginTop: 14, flexWrap: "wrap", alignItems: "center" }}>
        <div style={{ display: "flex", gap: 6, overflowX: "auto", WebkitOverflowScrolling: "touch", whiteSpace: "nowrap", flex: 1, minWidth: 0 }}>
          {[{ id: "all", label: "All" }, ...REFERRAL_STATUSES].map(f => (
            <button
              key={f.id}
              onClick={() => setStatusFilter(f.id)}
              style={{
                padding: "6px 12px", fontSize: 12, fontWeight: statusFilter === f.id ? 600 : 400,
                color: statusFilter === f.id ? T.white : T.slate700,
                background: statusFilter === f.id ? T.chromeBgDeep : T.white,
                border: `1px solid ${statusFilter === f.id ? T.chromeBgDeep : T.slate200}`,
                borderRadius: 7, cursor: "pointer", flexShrink: 0,
              }}
            >{f.label}</button>
          ))}
        </div>
        <button
          onClick={() => setShowAdd(v => !v)}
          style={{
            padding: "6px 14px", fontSize: 12, fontWeight: 600,
            color: T.white, background: T.chromeBg, border: "none", borderRadius: 7, cursor: "pointer", flexShrink: 0,
          }}
        >{showAdd ? "Cancel" : "+ Add Referral"}</button>
      </div>

      {showAdd && (
        <div style={{ marginTop: 12, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: 14 }}>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: 10 }}>
            <InputRow label="Referred by (name)">
              <input value={form.referred_by_name} onChange={e => setForm({ ...form, referred_by_name: e.target.value })} style={inputStyle} placeholder="e.g. Jane Smith" />
            </InputRow>
            <InputRow label="Referred household">
              <input value={form.referred_household_name} onChange={e => setForm({ ...form, referred_household_name: e.target.value })} style={inputStyle} placeholder="Household or contact name" />
            </InputRow>
            <InputRow label="Source">
              <select value={form.referral_source} onChange={e => setForm({ ...form, referral_source: e.target.value })} style={inputStyle}>
                <option value="customer">Customer</option>
                <option value="employee">Employee</option>
                <option value="partner">Partner</option>
                <option value="family">Family</option>
                <option value="other">Other</option>
              </select>
            </InputRow>
            <InputRow label="Assigned to">
              <select value={form.assigned_to} onChange={e => setForm({ ...form, assigned_to: e.target.value })} style={inputStyle}>
                <option value="">— Unassigned —</option>
                {team.map(t => <option key={t.id} value={t.id}>{t.first_name} {t.last_name}</option>)}
              </select>
            </InputRow>
            <InputRow label="Referred date">
              <input type="date" value={form.referred_at} onChange={e => setForm({ ...form, referred_at: e.target.value })} style={inputStyle} />
            </InputRow>
            <InputRow label="Notes">
              <input value={form.notes} onChange={e => setForm({ ...form, notes: e.target.value })} style={inputStyle} placeholder="Optional" />
            </InputRow>
          </div>
          {err && <div style={{ color: "#991B1B", fontSize: 12, marginTop: 8 }}>{err}</div>}
          <div style={{ marginTop: 12, textAlign: "right" }}>
            <button
              onClick={handleAdd}
              disabled={saving}
              style={{
                padding: "8px 16px", fontSize: 12, fontWeight: 700,
                color: T.white, background: saving ? T.slate400 : T.green, border: "none", borderRadius: 7,
                cursor: saving ? "not-allowed" : "pointer",
              }}
            >{saving ? "Saving…" : "Save Referral"}</button>
          </div>
        </div>
      )}

      <div style={{ marginTop: 12, overflowX: "auto", WebkitOverflowScrolling: "touch", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10 }}>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12, minWidth: 720 }}>
          <thead>
            <tr style={{ background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
              <th style={thStyle}>Referred By</th>
              <th style={thStyle}>Household</th>
              <th style={thStyle}>Date</th>
              <th style={thStyle}>Assigned</th>
              <th style={thStyle}>Source</th>
              <th style={thStyle}>Status</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Premium</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Spiff</th>
            </tr>
          </thead>
          <tbody>
            {filtered.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 24, textAlign: "center", color: T.slate500 }}>
                No referrals {statusFilter === "all" ? "yet" : `with status "${statusFilter}"`}. Click <strong>+ Add Referral</strong> to log one.
              </td></tr>
            )}
            {filtered.map(r => {
              const statusMeta = REFERRAL_STATUSES.find(s => s.id === r.status) || REFERRAL_STATUSES[0];
              return (
                <tr key={r.id} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                  <td style={{ ...tdStyle, fontWeight: 600 }}>{r.referred_by_name}</td>
                  <td style={tdStyle}>{r.referred_household_name}</td>
                  <td style={tdStyle}>{r.referred_at || "—"}</td>
                  <td style={tdStyle}>{nameFor(r.assigned_to, team)}</td>
                  <td style={{ ...tdStyle, color: T.slate500, fontSize: 11 }}>{r.referral_source || "—"}</td>
                  <td style={tdStyle}>
                    <button
                      onClick={() => advanceStatus(r)}
                      title="Click to advance status"
                      style={{
                        padding: "3px 10px", fontSize: 11, fontWeight: 600,
                        color: T.white, background: statusMeta.color, border: "none", borderRadius: 4,
                        cursor: "pointer",
                      }}
                    >{statusMeta.label}</button>
                  </td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{r.bind_premium ? fmtMoney(r.bind_premium) : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right", color: r.spiff_paid_at ? T.green : T.slate500 }}>
                    {r.spiff_amount ? fmtMoney(r.spiff_amount) : "—"}
                    {r.spiff_paid_at && <span style={{ marginLeft: 4, fontSize: 10 }}>✓</span>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div style={{ marginTop: 10, fontSize: 11, color: T.slate500, lineHeight: 1.6 }}>
        Click the status pill to advance: received → contacted → quoted → sold → dead → received. Quoted/sold dates auto-set. Weekly per-teammate marketing points are entered inline on the <strong>CPR &gt; Payroll</strong> section (edit mode); that stays canonical for the 7/11 pool rollout.
      </div>
    </div>
  );
}

// ─── Reviews sub-view ─────────────────────────────────────────
function ReviewsView({ rows, team, onReload }) {
  const vp = useViewport();
  const [showAdd, setShowAdd] = useState(false);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState(null);
  const [form, setForm] = useState({
    reviewer_name: "",
    rating: 5,
    review_text: "",
    review_date: new Date().toISOString().slice(0, 10),
    attributed_to: "",
  });

  const kpiCols = vp.isPhone ? "repeat(auto-fit, minmax(120px, 1fr))" : "repeat(auto-fit, minmax(140px, 1fr))";
  const yr = String(new Date().getFullYear());
  const ytdRows = rows.filter(r => r.review_date?.slice(0, 4) === yr);
  const totalYtd = ytdRows.length;
  const avgRating = totalYtd > 0 ? (ytdRows.reduce((s, r) => s + (Number(r.rating) || 0), 0) / totalYtd) : null;
  const respondedCount = ytdRows.filter(r => !!r.responded_at).length;
  const responseRate = totalYtd > 0 ? respondedCount / totalYtd : null;
  const needsResponse = rows.filter(r => !r.responded_at).length;
  const fiveStarCount = ytdRows.filter(r => Number(r.rating) === 5).length;
  const avgTone = avgRating == null ? "neutral" : avgRating >= 4.5 ? "good" : avgRating >= 4 ? "neutral" : "warn";
  const respTone = responseRate == null ? "neutral" : responseRate >= 0.9 ? "good" : responseRate >= 0.5 ? "neutral" : "warn";
  const needsTone = needsResponse === 0 ? "good" : needsResponse >= 3 ? "warn" : "neutral";

  const handleAdd = async () => {
    if (!form.reviewer_name.trim()) { setErr("Reviewer name required."); return; }
    const rt = Number(form.rating);
    if (!(rt >= 1 && rt <= 5)) { setErr("Rating must be 1–5."); return; }
    setSaving(true); setErr(null);
    try {
      const payload = {
        agency_id: AGENCY_ID,
        reviewer_name: form.reviewer_name.trim(),
        rating: rt,
        review_text: form.review_text || null,
        review_date: form.review_date || null,
        attributed_to: form.attributed_to || null,
        icp_flag: rt === 5,
      };
      const { error } = await supabase.from("gbp_reviews").insert(payload);
      if (error) throw error;
      setShowAdd(false);
      setForm({
        reviewer_name: "",
        rating: 5,
        review_text: "",
        review_date: new Date().toISOString().slice(0, 10),
        attributed_to: "",
      });
      onReload();
    } catch (e) {
      setErr(e?.message || String(e));
    } finally {
      setSaving(false);
    }
  };

  const markResponded = async (row) => {
    await supabase.from("gbp_reviews").update({ responded_at: new Date().toISOString() }).eq("id", row.id);
    onReload();
  };
  const unmarkResponded = async (row) => {
    await supabase.from("gbp_reviews").update({ responded_at: null, responded_by: null }).eq("id", row.id);
    onReload();
  };

  return (
    <div>
      <SectionTitle>Reviews YTD</SectionTitle>
      <div style={{ display: "grid", gridTemplateColumns: kpiCols, gap: 10 }}>
        <KpiCard label="Total Reviews" value={fmtInt(totalYtd)} sub={`YTD ${yr}`} />
        <KpiCard label="Avg Rating" value={avgRating != null ? avgRating.toFixed(2) : "—"} sub={`${fiveStarCount} five-star`} tone={avgTone} />
        <KpiCard label="Response Rate" value={responseRate != null ? `${(responseRate * 100).toFixed(0)}%` : "—"} sub={`${respondedCount}/${totalYtd} responded`} tone={respTone} />
        <KpiCard label="Needs Response" value={fmtInt(needsResponse)} tone={needsTone} />
      </div>

      <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 14 }}>
        <button
          onClick={() => setShowAdd(v => !v)}
          style={{
            padding: "6px 14px", fontSize: 12, fontWeight: 600,
            color: T.white, background: T.chromeBg, border: "none", borderRadius: 7, cursor: "pointer",
          }}
        >{showAdd ? "Cancel" : "+ Log Review"}</button>
      </div>

      {showAdd && (
        <div style={{ marginTop: 12, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: 14 }}>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: 10 }}>
            <InputRow label="Reviewer name">
              <input value={form.reviewer_name} onChange={e => setForm({ ...form, reviewer_name: e.target.value })} style={inputStyle} />
            </InputRow>
            <InputRow label="Rating (1-5)">
              <select value={form.rating} onChange={e => setForm({ ...form, rating: Number(e.target.value) })} style={inputStyle}>
                {[5,4,3,2,1].map(n => <option key={n} value={n}>{"★".repeat(n)}{"☆".repeat(5-n)} — {n}</option>)}
              </select>
            </InputRow>
            <InputRow label="Review date">
              <input type="date" value={form.review_date} onChange={e => setForm({ ...form, review_date: e.target.value })} style={inputStyle} />
            </InputRow>
            <InputRow label="Attributed to">
              <select value={form.attributed_to} onChange={e => setForm({ ...form, attributed_to: e.target.value })} style={inputStyle}>
                <option value="">— Nobody —</option>
                {team.map(t => <option key={t.id} value={t.id}>{t.first_name} {t.last_name}</option>)}
              </select>
            </InputRow>
            <InputRow label="Review text" span>
              <textarea value={form.review_text} onChange={e => setForm({ ...form, review_text: e.target.value })} style={{ ...inputStyle, minHeight: 60, resize: "vertical" }} />
            </InputRow>
          </div>
          {err && <div style={{ color: "#991B1B", fontSize: 12, marginTop: 8 }}>{err}</div>}
          <div style={{ marginTop: 12, textAlign: "right" }}>
            <button
              onClick={handleAdd}
              disabled={saving}
              style={{
                padding: "8px 16px", fontSize: 12, fontWeight: 700,
                color: T.white, background: saving ? T.slate400 : T.green, border: "none", borderRadius: 7,
                cursor: saving ? "not-allowed" : "pointer",
              }}
            >{saving ? "Saving…" : "Save Review"}</button>
          </div>
        </div>
      )}

      <div style={{ marginTop: 12, overflowX: "auto", WebkitOverflowScrolling: "touch", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10 }}>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12, minWidth: 720 }}>
          <thead>
            <tr style={{ background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
              <th style={thStyle}>Rating</th>
              <th style={thStyle}>Reviewer</th>
              <th style={thStyle}>Snippet</th>
              <th style={thStyle}>Date</th>
              <th style={thStyle}>Attributed</th>
              <th style={thStyle}>Response</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr><td colSpan={6} style={{ padding: 24, textAlign: "center", color: T.slate500 }}>
                No reviews logged yet. Click <strong>+ Log Review</strong> to add one.
              </td></tr>
            )}
            {rows.map(r => {
              const ratingColor = r.rating >= 4 ? T.green : r.rating >= 3 ? T.gold : T.red;
              const snippet = (r.review_text || "").slice(0, 80);
              return (
                <tr key={r.id} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                  <td style={{ ...tdStyle, color: ratingColor, fontWeight: 700, whiteSpace: "nowrap" }}>
                    {"★".repeat(r.rating)}{"☆".repeat(5 - r.rating)}
                    {r.icp_flag && <span style={{ marginLeft: 6, fontSize: 10, background: T.goldLt, color: T.gold, padding: "1px 5px", borderRadius: 3 }}>ICP</span>}
                  </td>
                  <td style={{ ...tdStyle, fontWeight: 600 }}>{r.reviewer_name}</td>
                  <td style={{ ...tdStyle, color: T.slate500, maxWidth: 260 }}>
                    {snippet}{(r.review_text || "").length > 80 ? "…" : ""}
                  </td>
                  <td style={tdStyle}>{r.review_date || "—"}</td>
                  <td style={tdStyle}>{nameFor(r.attributed_to, team)}</td>
                  <td style={tdStyle}>
                    {r.responded_at ? (
                      <button onClick={() => unmarkResponded(r)} style={{
                        padding: "3px 8px", fontSize: 11, fontWeight: 600,
                        color: T.green, background: T.greenLt, border: `1px solid #86EFAC`, borderRadius: 4, cursor: "pointer",
                      }} title="Click to un-mark">✓ Responded</button>
                    ) : (
                      <button onClick={() => markResponded(r)} style={{
                        padding: "3px 8px", fontSize: 11, fontWeight: 600,
                        color: T.white, background: T.chromeBg, border: "none", borderRadius: 4, cursor: "pointer",
                      }}>Mark responded</button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div style={{ marginTop: 10, fontSize: 11, color: T.slate500, lineHeight: 1.6 }}>
        5-star reviews auto-tag as <strong>ICP</strong> (Ideal Customer Profile research pool). Weekly per-teammate marketing points are entered inline on the <strong>CPR &gt; Payroll</strong> section (edit mode).
      </div>
    </div>
  );
}

const inputStyle = {
  width: "100%", padding: "7px 9px", fontSize: 12,
  border: `1px solid ${T.slate200}`, borderRadius: 6, background: T.white, color: T.slate900,
  outline: "none", boxSizing: "border-box",
};
function InputRow({ label, span, children }) {
  return (
    <label style={{ display: "flex", flexDirection: "column", gap: 4, gridColumn: span ? "1 / -1" : "auto" }}>
      <span style={{ fontSize: 11, color: T.slate500, fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.03em" }}>{label}</span>
      {children}
    </label>
  );
}

function ReferralsReviewsTab() {
  const vp = useViewport();
  const [subTab, setSubTab] = useTabParam("subtab", "referrals", ["referrals","reviews"]);
  const { loading, referrals, reviews, error, reload } = useRefRevData();
  const team = useTeamRoster();

  if (loading) return <div style={{ padding: 40, textAlign: "center", color: T.slate500, fontSize: 13 }}>Loading…</div>;
  if (error) return <div style={{ padding: 20, color: "#991B1B", fontSize: 13 }}>Error: {error}</div>;

  return (
    <div>
      <div style={{
        display: "flex", gap: 4, background: T.slate100, borderRadius: 8,
        padding: 3, marginBottom: 14, width: "fit-content", maxWidth: "100%",
      }}>
        {[
          { id: "referrals", label: `Referrals (${referrals.length})` },
          { id: "reviews",   label: `Reviews (${reviews.length})` },
        ].map(t => (
          <button
            key={t.id}
            onClick={() => setSubTab(t.id)}
            style={{
              padding: "5px 12px", fontSize: 12,
              fontWeight: subTab === t.id ? 600 : 400,
              color: subTab === t.id ? T.slate900 : T.slate500,
              background: subTab === t.id ? T.white : "transparent",
              border: "none", borderRadius: 6, cursor: "pointer",
              boxShadow: subTab === t.id ? "0 1px 3px rgba(0,0,0,0.08)" : "none",
            }}
          >{t.label}</button>
        ))}
      </div>

      {subTab === "referrals" && <ReferralsView rows={referrals} team={team} onReload={reload} />}
      {subTab === "reviews" && <ReviewsView rows={reviews} team={team} onReload={reload} />}
    </div>
  );
}


// ─── Ideas Backlog Tab ────────────────────────────────────────
const IDEA_STATUSES = [
  { id: "backlog",     label: "Backlog",     color: T.slate500 },
  { id: "next_review", label: "Next Review", color: T.slate700 },
  { id: "approved",    label: "Approved",    color: T.chromeBg },
  { id: "in_flight",   label: "In Flight",   color: T.gold },
  { id: "done",        label: "Done",        color: T.green },
  { id: "rejected",    label: "Rejected",    color: T.red },
];

const IDEA_STATUS_ORDER = ["backlog","next_review","approved","in_flight","done","rejected"];

function useIdeasData() {
  const [state, setState] = useState({ loading: true, ideas: [], error: null, tick: 0 });
  const reload = () => setState(s => ({ ...s, tick: s.tick + 1 }));
  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        setState(s => ({ ...s, loading: true, error: null }));
        const { data, error } = await supabase
          .from("marketing_ideas")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .order("created_at", { ascending: false });
        if (cancelled) return;
        if (error) throw error;
        setState(s => ({ ...s, loading: false, ideas: Array.isArray(data) ? data : [] }));
      } catch (err) {
        if (!cancelled) setState(s => ({ ...s, loading: false, error: err?.message || String(err) }));
      }
    }
    load();
    return () => { cancelled = true; };
  }, [state.tick]);
  return { ...state, reload };
}

function midCost(idea) {
  const lo = Number(idea?.estimated_cost_low);
  const hi = Number(idea?.estimated_cost_high);
  const loOk = Number.isFinite(lo);
  const hiOk = Number.isFinite(hi);
  if (loOk && hiOk) return (lo + hi) / 2;
  if (loOk) return lo;
  if (hiOk) return hi;
  return null;
}

function formatCostRange(idea) {
  const lo = Number(idea?.estimated_cost_low);
  const hi = Number(idea?.estimated_cost_high);
  const loOk = Number.isFinite(lo);
  const hiOk = Number.isFinite(hi);
  if (loOk && hiOk) return lo === hi ? fmtMoney(lo) : `${fmtMoney(lo)}–${fmtMoney(hi)}`;
  if (loOk) return `≥ ${fmtMoney(lo)}`;
  if (hiOk) return `≤ ${fmtMoney(hi)}`;
  return null;
}

function IdeaCard({ idea, onAdvance, onPromote, onEdit, promoting, editingId, editForm, setEditForm, saveEdit, cancelEdit }) {
  const status = IDEA_STATUSES.find(s => s.id === idea.status) || IDEA_STATUSES[0];
  const costLabel = formatCostRange(idea);
  const isEditing = editingId === idea.id;
  const promoted = !!idea.promoted_to_task_id;

  return (
    <div style={{
      background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10,
      padding: 14, display: "flex", flexDirection: "column", gap: 8, minHeight: 140,
    }}>
      {isEditing ? (
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <InputRow label="Title">
            <input value={editForm.title} onChange={e => setEditForm({ ...editForm, title: e.target.value })} style={inputStyle} />
          </InputRow>
          <InputRow label="Category">
            <input value={editForm.category || ""} onChange={e => setEditForm({ ...editForm, category: e.target.value })} style={inputStyle} placeholder="e.g. paid_leads, social_content" />
          </InputRow>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
            <InputRow label="Cost Low $">
              <input type="number" step="1" value={editForm.estimated_cost_low ?? ""} onChange={e => setEditForm({ ...editForm, estimated_cost_low: e.target.value === "" ? null : Number(e.target.value) })} style={inputStyle} />
            </InputRow>
            <InputRow label="Cost High $">
              <input type="number" step="1" value={editForm.estimated_cost_high ?? ""} onChange={e => setEditForm({ ...editForm, estimated_cost_high: e.target.value === "" ? null : Number(e.target.value) })} style={inputStyle} />
            </InputRow>
          </div>
          <InputRow label="Effort">
            <select value={editForm.estimated_effort || ""} onChange={e => setEditForm({ ...editForm, estimated_effort: e.target.value || null })} style={inputStyle}>
              <option value="">— unset —</option>
              <option value="quick">Quick (≤ 2h)</option>
              <option value="small">Small (½ day)</option>
              <option value="medium">Medium (1–3 days)</option>
              <option value="large">Large (1+ weeks)</option>
            </select>
          </InputRow>
          <InputRow label="Expected return / notes" span>
            <textarea value={editForm.expected_return_notes || ""} onChange={e => setEditForm({ ...editForm, expected_return_notes: e.target.value })} style={{ ...inputStyle, minHeight: 44, resize: "vertical" }} />
          </InputRow>
          <div style={{ display: "flex", gap: 6, justifyContent: "flex-end" }}>
            <button onClick={cancelEdit} style={{ padding: "5px 10px", fontSize: 11, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 5, cursor: "pointer" }}>Cancel</button>
            <button onClick={() => saveEdit(idea.id)} style={{ padding: "5px 10px", fontSize: 11, background: T.green, color: T.white, border: "none", borderRadius: 5, cursor: "pointer", fontWeight: 600 }}>Save</button>
          </div>
        </div>
      ) : (
        <>
          <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 8 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: T.slate900, lineHeight: 1.35, flex: 1 }}>
              {idea.title}
            </div>
            <button
              onClick={() => onAdvance(idea)}
              title="Click to advance status"
              style={{
                padding: "3px 8px", fontSize: 10, fontWeight: 700,
                color: T.white, background: status.color, border: "none", borderRadius: 4,
                cursor: "pointer", whiteSpace: "nowrap", flexShrink: 0, textTransform: "uppercase", letterSpacing: "0.03em",
              }}
            >{status.label}</button>
          </div>

          {idea.category && (
            <div style={{ fontSize: 10, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.05em", fontWeight: 600 }}>
              {idea.category}
            </div>
          )}

          {idea.description && (
            <div style={{ fontSize: 12, color: T.slate600, lineHeight: 1.5 }}>
              {idea.description.length > 220 ? `${idea.description.slice(0, 220)}…` : idea.description}
            </div>
          )}

          <div style={{ display: "flex", gap: 8, flexWrap: "wrap", fontSize: 11, color: T.slate500 }}>
            {costLabel && (
              <div style={{ background: T.slate50, padding: "2px 7px", borderRadius: 4 }}>
                💰 {costLabel}
              </div>
            )}
            {idea.estimated_effort && (
              <div style={{ background: T.slate50, padding: "2px 7px", borderRadius: 4 }}>
                ⏱ {idea.estimated_effort}
              </div>
            )}
            {idea.expected_return_notes && (
              <div style={{ background: T.greenLt, color: "#065F46", padding: "2px 7px", borderRadius: 4, maxWidth: "100%" }} title={idea.expected_return_notes}>
                📈 {idea.expected_return_notes.length > 30 ? `${idea.expected_return_notes.slice(0, 30)}…` : idea.expected_return_notes}
              </div>
            )}
            {promoted && (
              <div style={{ background: T.goldLt, color: T.gold, padding: "2px 7px", borderRadius: 4, fontWeight: 600 }}>
                → Task created
              </div>
            )}
          </div>

          <div style={{ display: "flex", gap: 6, marginTop: "auto", paddingTop: 6, flexWrap: "wrap" }}>
            <button
              onClick={() => onEdit(idea)}
              style={{ padding: "4px 10px", fontSize: 11, background: T.white, color: T.slate700, border: `1px solid ${T.slate200}`, borderRadius: 5, cursor: "pointer" }}
            >Edit</button>
            {!promoted && (
              <button
                onClick={() => onPromote(idea)}
                disabled={promoting === idea.id}
                style={{
                  padding: "4px 10px", fontSize: 11, fontWeight: 600,
                  background: promoting === idea.id ? T.slate400 : T.chromeBg, color: T.white,
                  border: "none", borderRadius: 5,
                  cursor: promoting === idea.id ? "not-allowed" : "pointer",
                }}
              >{promoting === idea.id ? "Promoting…" : "→ Promote to task"}</button>
            )}
          </div>
        </>
      )}
    </div>
  );
}

function IdeasTab() {
  const vp = useViewport();
  const { loading, ideas, error, reload } = useIdeasData();
  const [statusFilter, setStatusFilter] = useState("backlog");
  const [categoryFilter, setCategoryFilter] = useState("all");
  const [sortBy, setSortBy] = useState("newest");
  const [showAdd, setShowAdd] = useState(false);
  const [promoting, setPromoting] = useState(null);
  const [editingId, setEditingId] = useState(null);
  const [editForm, setEditForm] = useState({});
  const [addForm, setAddForm] = useState({
    title: "", description: "", category: "", estimated_effort: "",
    estimated_cost_low: null, estimated_cost_high: null,
    expected_return_notes: "",
  });
  const [addErr, setAddErr] = useState(null);
  const [saving, setSaving] = useState(false);

  if (loading) return <div style={{ padding: 40, textAlign: "center", color: T.slate500, fontSize: 13 }}>Loading…</div>;
  if (error) return <div style={{ padding: 20, color: "#991B1B", fontSize: 13 }}>Error: {error}</div>;

  // Distinct categories from data + "all"
  const categoriesInUse = Array.from(new Set(ideas.map(i => i.category).filter(Boolean))).sort();

  // Status counts (all ideas, unfiltered)
  const countByStatus = {};
  IDEA_STATUS_ORDER.forEach(s => { countByStatus[s] = 0; });
  ideas.forEach(i => {
    if (countByStatus[i.status] != null) countByStatus[i.status] += 1;
    else countByStatus[i.status] = 1;
  });

  // Cost estimation counts
  const withCostCount = ideas.filter(i => midCost(i) != null).length;
  const totalEstMid = ideas.reduce((sum, i) => sum + (midCost(i) || 0), 0);

  // Filter + sort
  let filtered = ideas.filter(i => {
    if (statusFilter !== "all" && i.status !== statusFilter) return false;
    if (categoryFilter !== "all" && i.category !== categoryFilter) return false;
    return true;
  });
  filtered = [...filtered].sort((a, b) => {
    if (sortBy === "newest") return (b.created_at || "").localeCompare(a.created_at || "");
    if (sortBy === "oldest") return (a.created_at || "").localeCompare(b.created_at || "");
    if (sortBy === "cost_low") return (midCost(a) ?? 1e15) - (midCost(b) ?? 1e15);
    if (sortBy === "cost_high") return (midCost(b) ?? -1) - (midCost(a) ?? -1);
    if (sortBy === "category") return (a.category || "~").localeCompare(b.category || "~");
    if (sortBy === "alpha") return (a.title || "").localeCompare(b.title || "");
    return 0;
  });

  const advanceStatus = async (idea) => {
    const idx = IDEA_STATUS_ORDER.indexOf(idea.status);
    const next = IDEA_STATUS_ORDER[(idx + 1) % IDEA_STATUS_ORDER.length];
    const patch = { status: next };
    if (next === "next_review" && !idea.next_review_at) patch.next_review_at = new Date().toISOString();
    if (next === "approved" && !idea.decided_at) patch.decided_at = new Date().toISOString();
    if (next === "done" && !idea.decided_at) patch.decided_at = new Date().toISOString();
    if (next === "rejected" && !idea.decided_at) patch.decided_at = new Date().toISOString();
    if ((next === "next_review" || next === "approved") && !idea.reviewed_at) patch.reviewed_at = new Date().toISOString();
    const { error } = await supabase.from("marketing_ideas").update(patch).eq("id", idea.id);
    if (error) { alert("Advance failed: " + error.message); return; }
    reload();
  };

  const promoteToTask = async (idea) => {
    setPromoting(idea.id);
    try {
      const taskPayload = {
        agency_id: AGENCY_ID,
        title: idea.title,
        description: idea.description || `Promoted from marketing idea. Category: ${idea.category || "n/a"}. ${idea.expected_return_notes ? "Expected return: " + idea.expected_return_notes : ""}`,
        priority: "medium",
        status: "open",
        task_category: "marketing",
        task_type: "task",
        in_weekly_focus: false,
        assigned_to: null,
        created_by: "Marketing module — promoted from idea",
      };
      const { data: task, error: taskErr } = await supabase.from("tasks").insert(taskPayload).select().maybeSingle();
      if (taskErr) throw taskErr;
      if (!task?.id) throw new Error("Task created but no id returned");
      const { error: ideaErr } = await supabase
        .from("marketing_ideas")
        .update({ promoted_to_task_id: task.id, status: "in_flight", decided_at: new Date().toISOString() })
        .eq("id", idea.id);
      if (ideaErr) throw ideaErr;
      reload();
    } catch (e) {
      alert("Promote failed: " + (e?.message || String(e)));
    } finally {
      setPromoting(null);
    }
  };

  const openEdit = (idea) => {
    setEditingId(idea.id);
    setEditForm({
      title: idea.title || "",
      category: idea.category || "",
      estimated_cost_low: idea.estimated_cost_low,
      estimated_cost_high: idea.estimated_cost_high,
      estimated_effort: idea.estimated_effort || "",
      expected_return_notes: idea.expected_return_notes || "",
    });
  };
  const cancelEdit = () => { setEditingId(null); setEditForm({}); };
  const saveEdit = async (id) => {
    const patch = {
      title: editForm.title?.trim() || null,
      category: editForm.category?.trim() || null,
      estimated_cost_low: editForm.estimated_cost_low,
      estimated_cost_high: editForm.estimated_cost_high,
      estimated_effort: editForm.estimated_effort || null,
      expected_return_notes: editForm.expected_return_notes?.trim() || null,
    };
    const { error } = await supabase.from("marketing_ideas").update(patch).eq("id", id);
    if (error) { alert("Save failed: " + error.message); return; }
    cancelEdit();
    reload();
  };

  const handleAdd = async () => {
    if (!addForm.title.trim()) { setAddErr("Title required."); return; }
    setSaving(true); setAddErr(null);
    try {
      const payload = {
        agency_id: AGENCY_ID,
        title: addForm.title.trim(),
        description: addForm.description || null,
        category: addForm.category?.trim() || null,
        estimated_effort: addForm.estimated_effort || null,
        estimated_cost_low: addForm.estimated_cost_low,
        estimated_cost_high: addForm.estimated_cost_high,
        expected_return_notes: addForm.expected_return_notes || null,
        status: "backlog",
      };
      const { error } = await supabase.from("marketing_ideas").insert(payload);
      if (error) throw error;
      setShowAdd(false);
      setAddForm({ title: "", description: "", category: "", estimated_effort: "", estimated_cost_low: null, estimated_cost_high: null, expected_return_notes: "" });
      reload();
    } catch (e) {
      setAddErr(e?.message || String(e));
    } finally {
      setSaving(false);
    }
  };

  const cardCols = vp.isPhone ? "1fr" : "repeat(auto-fill, minmax(300px, 1fr))";
  const kpiCols = vp.isPhone ? "repeat(auto-fit, minmax(100px, 1fr))" : "repeat(auto-fit, minmax(120px, 1fr))";

  return (
    <div>
      <SectionTitle>Pipeline</SectionTitle>
      <div style={{ display: "grid", gridTemplateColumns: kpiCols, gap: 8 }}>
        {IDEA_STATUSES.map(s => (
          <button
            key={s.id}
            onClick={() => setStatusFilter(s.id)}
            style={{
              background: statusFilter === s.id ? s.color : T.white,
              color: statusFilter === s.id ? T.white : T.slate900,
              border: `1px solid ${statusFilter === s.id ? s.color : T.slate200}`,
              borderRadius: 10, padding: "10px 12px", cursor: "pointer",
              textAlign: "left", display: "flex", flexDirection: "column", gap: 3, minHeight: 62,
            }}
          >
            <div style={{ fontSize: 10, fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em", opacity: statusFilter === s.id ? 0.85 : 0.6 }}>{s.label}</div>
            <div style={{ fontSize: 20, fontWeight: 700, letterSpacing: "-0.02em" }}>{countByStatus[s.id] || 0}</div>
          </button>
        ))}
      </div>
      <div style={{ marginTop: 10, fontSize: 11, color: T.slate500 }}>
        {ideas.length} total ideas · {withCostCount} with cost estimate · <strong>{fmtMoney(totalEstMid)}</strong> total estimated cost midpoint
      </div>

      {/* Filter + sort + add row */}
      <div style={{ display: "flex", gap: 8, marginTop: 14, flexWrap: "wrap", alignItems: "center" }}>
        <div style={{ display: "flex", gap: 6, overflowX: "auto", WebkitOverflowScrolling: "touch", whiteSpace: "nowrap", flex: 1, minWidth: 0 }}>
          <button
            onClick={() => setStatusFilter("all")}
            style={{
              padding: "6px 12px", fontSize: 12, fontWeight: statusFilter === "all" ? 600 : 400,
              color: statusFilter === "all" ? T.white : T.slate700,
              background: statusFilter === "all" ? T.chromeBgDeep : T.white,
              border: `1px solid ${statusFilter === "all" ? T.chromeBgDeep : T.slate200}`,
              borderRadius: 7, cursor: "pointer", flexShrink: 0,
            }}
          >All ({ideas.length})</button>

          <select value={categoryFilter} onChange={e => setCategoryFilter(e.target.value)} style={{
            padding: "6px 10px", fontSize: 12, fontWeight: 600, color: T.slate700,
            background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 7, cursor: "pointer", flexShrink: 0,
          }}>
            <option value="all">All categories</option>
            {categoriesInUse.map(c => <option key={c} value={c}>{c}</option>)}
          </select>

          <select value={sortBy} onChange={e => setSortBy(e.target.value)} style={{
            padding: "6px 10px", fontSize: 12, fontWeight: 600, color: T.slate700,
            background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 7, cursor: "pointer", flexShrink: 0,
          }}>
            <option value="newest">Sort: Newest</option>
            <option value="oldest">Sort: Oldest</option>
            <option value="cost_low">Sort: Cost ↑</option>
            <option value="cost_high">Sort: Cost ↓</option>
            <option value="category">Sort: Category</option>
            <option value="alpha">Sort: A→Z</option>
          </select>
        </div>
        <button
          onClick={() => setShowAdd(v => !v)}
          style={{
            padding: "6px 14px", fontSize: 12, fontWeight: 600,
            color: T.white, background: T.chromeBg, border: "none", borderRadius: 7, cursor: "pointer", flexShrink: 0,
          }}
        >{showAdd ? "Cancel" : "+ Add Idea"}</button>
      </div>

      {showAdd && (
        <div style={{ marginTop: 12, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: 14 }}>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: 10 }}>
            <InputRow label="Title" span>
              <input value={addForm.title} onChange={e => setAddForm({ ...addForm, title: e.target.value })} style={inputStyle} placeholder="e.g. Try local church sponsorship" />
            </InputRow>
            <InputRow label="Category">
              <input value={addForm.category} onChange={e => setAddForm({ ...addForm, category: e.target.value })} style={inputStyle} placeholder="e.g. community_event" list="ideas-cat-suggest" />
              <datalist id="ideas-cat-suggest">
                {categoriesInUse.map(c => <option key={c} value={c} />)}
              </datalist>
            </InputRow>
            <InputRow label="Effort">
              <select value={addForm.estimated_effort} onChange={e => setAddForm({ ...addForm, estimated_effort: e.target.value })} style={inputStyle}>
                <option value="">— unset —</option>
                <option value="quick">Quick (≤ 2h)</option>
                <option value="small">Small (½ day)</option>
                <option value="medium">Medium (1–3 days)</option>
                <option value="large">Large (1+ weeks)</option>
              </select>
            </InputRow>
            <InputRow label="Cost Low $">
              <input type="number" step="1" value={addForm.estimated_cost_low ?? ""} onChange={e => setAddForm({ ...addForm, estimated_cost_low: e.target.value === "" ? null : Number(e.target.value) })} style={inputStyle} />
            </InputRow>
            <InputRow label="Cost High $">
              <input type="number" step="1" value={addForm.estimated_cost_high ?? ""} onChange={e => setAddForm({ ...addForm, estimated_cost_high: e.target.value === "" ? null : Number(e.target.value) })} style={inputStyle} />
            </InputRow>
            <InputRow label="Description" span>
              <textarea value={addForm.description} onChange={e => setAddForm({ ...addForm, description: e.target.value })} style={{ ...inputStyle, minHeight: 60, resize: "vertical" }} placeholder="What is it? Why?" />
            </InputRow>
            <InputRow label="Expected return / notes" span>
              <textarea value={addForm.expected_return_notes} onChange={e => setAddForm({ ...addForm, expected_return_notes: e.target.value })} style={{ ...inputStyle, minHeight: 44, resize: "vertical" }} placeholder="Optional — what do we expect this to produce?" />
            </InputRow>
          </div>
          {addErr && <div style={{ color: "#991B1B", fontSize: 12, marginTop: 8 }}>{addErr}</div>}
          <div style={{ marginTop: 12, textAlign: "right" }}>
            <button
              onClick={handleAdd}
              disabled={saving}
              style={{
                padding: "8px 16px", fontSize: 12, fontWeight: 700,
                color: T.white, background: saving ? T.slate400 : T.green, border: "none", borderRadius: 7,
                cursor: saving ? "not-allowed" : "pointer",
              }}
            >{saving ? "Saving…" : "Save Idea"}</button>
          </div>
        </div>
      )}

      <SectionTitle>
        {filtered.length} idea{filtered.length === 1 ? "" : "s"}
        {statusFilter !== "all" && ` — ${IDEA_STATUSES.find(s => s.id === statusFilter)?.label || statusFilter}`}
        {categoryFilter !== "all" && ` · ${categoryFilter}`}
      </SectionTitle>

      {filtered.length === 0 ? (
        <div style={{ padding: 30, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, textAlign: "center", color: T.slate500, fontSize: 13 }}>
          No ideas match this filter. {ideas.length > 0 && "Try clearing the filters above."}
        </div>
      ) : (
        <div style={{ display: "grid", gridTemplateColumns: cardCols, gap: 10 }}>
          {filtered.map(i => (
            <IdeaCard
              key={i.id}
              idea={i}
              onAdvance={advanceStatus}
              onPromote={promoteToTask}
              onEdit={openEdit}
              promoting={promoting}
              editingId={editingId}
              editForm={editForm}
              setEditForm={setEditForm}
              saveEdit={saveEdit}
              cancelEdit={cancelEdit}
            />
          ))}
        </div>
      )}

      <div style={{ marginTop: 18, fontSize: 11, color: T.slate500, lineHeight: 1.6 }}>
        Click a status pill on any card to advance it (backlog → next_review → approved → in_flight → done → rejected → back to backlog). Promoting creates a task in the Tasks module with category=marketing and moves the idea to <strong>In Flight</strong>.
      </div>
    </div>
  );
}


// ─── Economics Tab (Phase 5) ──────────────────────────────────
// LTV + payback per lead source. Combines lead_source_quarterly with agency
// commission rates + compute_lapse_rate to answer "which sources are actually
// profitable when we account for retention?" — beyond the surface-level CPA.
function useEconomicsData() {
  const [state, setState] = useState({ loading: true, sources: [], rates: null, lapse: [], error: null });
  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        const [sourcesRes, agencyRes, lapseRes] = await Promise.all([
          supabase.from("lead_source_quarterly")
            .select("*")
            .eq("agency_id", AGENCY_ID)
            .order("snapshot_date", { ascending: false }),
          supabase.from("agency")
            .select("pc_base_rate, smvc_rate_pc, blended_rate_other, aipp_rate")
            .eq("id", AGENCY_ID)
            .maybeSingle(),
          supabase.rpc("compute_lapse_rate", { p_agency_id: AGENCY_ID }),
        ]);
        if (cancelled) return;
        setState({
          loading: false,
          error: null,
          sources: Array.isArray(sourcesRes?.data) ? sourcesRes.data : [],
          rates: agencyRes?.data || null,
          lapse: Array.isArray(lapseRes?.data) ? lapseRes.data : [],
        });
      } catch (err) {
        if (!cancelled) setState(s => ({ ...s, loading: false, error: err?.message || String(err) }));
      }
    }
    load();
    return () => { cancelled = true; };
  }, []);
  return state;
}

function EconomicsTab() {
  const vp = useViewport();
  const { loading, sources, rates, lapse, error } = useEconomicsData();
  const [targetLapse, setTargetLapse] = useState(0.11); // aspirational retention target from userMemories
  const [selectedYear, setSelectedYear] = useState(new Date().getFullYear());
  const [selectedQuarter, setSelectedQuarter] = useState(Math.floor(new Date().getMonth() / 3) + 1);

  if (loading) return <div style={{ padding: 40, textAlign: "center", color: T.slate500, fontSize: 13 }}>Loading…</div>;
  if (error) return <div style={{ padding: 20, color: "#991B1B", fontSize: 13 }}>Error: {error}</div>;

  const pcBase = Number(rates?.pc_base_rate) || 0;
  const smvc = Number(rates?.smvc_rate_pc) || 0;
  const effectivePc = pcBase + smvc;

  // Blended annualized lapse from compute_lapse_rate
  const blendedLapseRow = lapse.find(r => r.line === "blended");
  const blendedLapse = blendedLapseRow ? Number(blendedLapseRow.annualized_rate) : null;
  const currentRetentionYears = blendedLapse != null && blendedLapse > 0 ? 1 / blendedLapse : null;
  const targetRetentionYears = targetLapse > 0 ? 1 / targetLapse : null;

  // Filter sources to selected quarter + latest snapshot per source
  const quarterSnaps = sources.filter(s => s.period_year === selectedYear && s.period_quarter === selectedQuarter);
  const latestBySource = {};
  quarterSnaps.forEach(r => {
    const key = `${r.source}::${r.source_type || "lead_source"}`;
    const prev = latestBySource[key];
    if (!prev || (r.snapshot_date > prev.snapshot_date)) latestBySource[key] = r;
  });
  const paidSources = Object.values(latestBySource).filter(s => s.source_type === "lead_source");

  // Per-source economics
  const rows = paidSources.map(s => {
    const hhs = Number(s.won_households) || 0;
    const premium = Number(s.won_premium) || 0;
    const cost = Number(s.cost_total) || 0;
    const y1Commission = premium * effectivePc;
    const ltvCurrent = blendedLapse != null && blendedLapse > 0 ? y1Commission / blendedLapse : null;
    const ltvTarget = targetLapse > 0 ? y1Commission / targetLapse : null;
    const paybackMonthsCurrent = y1Commission > 0 && cost > 0 ? (cost * 12) / y1Commission : null;
    const ltvOverCostCurrent = cost > 0 && ltvCurrent != null ? ltvCurrent / cost : null;
    const ltvOverCostTarget = cost > 0 && ltvTarget != null ? ltvTarget / cost : null;
    const cpa = hhs > 0 && cost > 0 ? cost / hhs : null;
    return {
      ...s, hhs, premium, cost, y1Commission,
      ltvCurrent, ltvTarget,
      paybackMonthsCurrent, ltvOverCostCurrent, ltvOverCostTarget, cpa,
    };
  }).sort((a, b) => (b.ltvOverCostCurrent ?? -1) - (a.ltvOverCostCurrent ?? -1));

  const kpiCols = vp.isPhone ? "repeat(auto-fit, minmax(140px, 1fr))" : "repeat(auto-fit, minmax(160px, 1fr))";

  return (
    <div>
      {/* Period selector */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6, flexWrap: "wrap" }}>
        <div style={{ fontSize: 12, color: T.slate500 }}>Quarter:</div>
        <select value={selectedQuarter} onChange={e => setSelectedQuarter(Number(e.target.value))} style={{
          padding: "6px 10px", fontSize: 12, fontWeight: 600, color: T.slate700,
          background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 7, cursor: "pointer",
        }}>
          {[1,2,3,4].map(q => <option key={q} value={q}>Q{q}</option>)}
        </select>
        <select value={selectedYear} onChange={e => setSelectedYear(Number(e.target.value))} style={{
          padding: "6px 10px", fontSize: 12, fontWeight: 600, color: T.slate700,
          background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 7, cursor: "pointer",
        }}>
          {[new Date().getFullYear() - 1, new Date().getFullYear()].map(y => <option key={y} value={y}>{y}</option>)}
        </select>
      </div>

      <SectionTitle>Assumptions</SectionTitle>
      <div style={{ display: "grid", gridTemplateColumns: kpiCols, gap: 10 }}>
        <KpiCard
          label="Effective P&C Rate"
          value={`${(effectivePc * 100).toFixed(2)}%`}
          sub={`Base ${(pcBase * 100).toFixed(1)}% + SMVC ${(smvc * 100).toFixed(2)}%`}
        />
        <KpiCard
          label="Current Blended Lapse"
          value={blendedLapse != null ? `${(blendedLapse * 100).toFixed(1)}%` : "—"}
          sub={blendedLapseRow?.source_snapshot_date ? `As of ${blendedLapseRow.source_snapshot_date} (annualized)` : ""}
          tone={blendedLapse != null && blendedLapse > 0.15 ? "warn" : "neutral"}
        />
        <KpiCard
          label="Retention Years (current)"
          value={currentRetentionYears != null ? currentRetentionYears.toFixed(2) : "—"}
          sub="1 ÷ lapse rate"
        />
        <KpiCard
          label="Target Retention Years"
          value={targetRetentionYears != null ? targetRetentionYears.toFixed(2) : "—"}
          sub={`If lapse were ${(targetLapse * 100).toFixed(1)}%`}
          tone="good"
        />
      </div>

      {/* Target lapse override slider/input */}
      <div style={{ marginTop: 12, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "10px 14px" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
          <div style={{ fontSize: 11, color: T.slate500, fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.03em" }}>
            Target lapse (what-if):
          </div>
          <input
            type="number" min="0.05" max="0.5" step="0.01"
            value={targetLapse}
            onChange={e => setTargetLapse(Math.max(0.01, Math.min(0.99, Number(e.target.value) || 0.11)))}
            style={{ ...inputStyle, width: 80 }}
          />
          <span style={{ fontSize: 12, color: T.slate500 }}>= {(targetLapse * 100).toFixed(1)}%</span>
          <div style={{ fontSize: 11, color: T.slate500, flexBasis: "100%" }}>
            Default 11% matches the retention aspiration. Tighten it to see LTV under improved retention.
          </div>
        </div>
      </div>

      <SectionTitle>Per-source economics — Q{selectedQuarter} {selectedYear}</SectionTitle>
      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10 }}>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12, minWidth: 780 }}>
          <thead>
            <tr style={{ background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
              <th style={thStyle}>Source</th>
              <th style={{ ...thStyle, textAlign: "right" }}>HHs</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Cost</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Y1 Comm</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Payback (mo)</th>
              <th style={{ ...thStyle, textAlign: "right" }}>LTV (current lapse)</th>
              <th style={{ ...thStyle, textAlign: "right" }}>LTV / Cost</th>
              <th style={{ ...thStyle, textAlign: "right" }}>LTV @ {(targetLapse * 100).toFixed(0)}% lapse</th>
              <th style={{ ...thStyle, textAlign: "right" }}>vs Target</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr><td colSpan={9} style={{ padding: 24, textAlign: "center", color: T.slate500 }}>
                No lead-source snapshots for Q{selectedQuarter} {selectedYear} with cost data.
              </td></tr>
            )}
            {rows.map(r => {
              const paybackColor = r.paybackMonthsCurrent == null ? T.slate500
                : r.paybackMonthsCurrent <= 12 ? "#065F46"
                : r.paybackMonthsCurrent <= 24 ? T.gold : "#991B1B";
              const ratioColor = r.ltvOverCostCurrent == null ? T.slate500
                : r.ltvOverCostCurrent >= 3 ? "#065F46"
                : r.ltvOverCostCurrent >= 1 ? T.gold : "#991B1B";
              return (
                <tr key={r.id} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                  <td style={{ ...tdStyle, fontWeight: 600 }}>{r.source}</td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{r.hhs > 0 ? fmtInt(r.hhs) : "0"}</td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{r.cost > 0 ? fmtMoney(r.cost) : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{r.y1Commission > 0 ? fmtMoney(r.y1Commission) : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right", color: paybackColor, fontWeight: 600 }}>
                    {r.paybackMonthsCurrent != null ? `${r.paybackMonthsCurrent.toFixed(1)}` : "—"}
                  </td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{r.ltvCurrent != null ? fmtMoney(r.ltvCurrent) : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right", color: ratioColor, fontWeight: 700 }}>
                    {r.ltvOverCostCurrent != null ? `${r.ltvOverCostCurrent.toFixed(2)}x` : "—"}
                  </td>
                  <td style={{ ...tdStyle, textAlign: "right", color: T.slate500 }}>{r.ltvTarget != null ? fmtMoney(r.ltvTarget) : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right", color: r.ltvOverCostTarget >= 3 ? "#065F46" : T.slate500 }}>
                    {r.ltvOverCostTarget != null ? `${r.ltvOverCostTarget.toFixed(2)}x` : "—"}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <SectionTitle>Lapse by line</SectionTitle>
      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10 }}>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12, minWidth: 460 }}>
          <thead>
            <tr style={{ background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
              <th style={thStyle}>Line</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Starting PIF</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Lost YTD</th>
              <th style={{ ...thStyle, textAlign: "right" }}>YTD Rate</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Annualized</th>
            </tr>
          </thead>
          <tbody>
            {lapse.map(l => (
              <tr key={l.line} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                <td style={{ ...tdStyle, fontWeight: 600, textTransform: "capitalize" }}>{l.line}</td>
                <td style={{ ...tdStyle, textAlign: "right" }}>{l.starting_pif != null ? fmtInt(l.starting_pif) : "—"}</td>
                <td style={{ ...tdStyle, textAlign: "right" }}>{l.lost_ytd != null ? fmtInt(l.lost_ytd) : "—"}</td>
                <td style={{ ...tdStyle, textAlign: "right" }}>{l.ytd_rate != null ? `${(Number(l.ytd_rate) * 100).toFixed(2)}%` : "—"}</td>
                <td style={{ ...tdStyle, textAlign: "right", fontWeight: 600, color: Number(l.annualized_rate) > 0.20 ? "#991B1B" : T.slate900 }}>
                  {l.annualized_rate != null ? `${(Number(l.annualized_rate) * 100).toFixed(2)}%` : "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div style={{ marginTop: 18, fontSize: 11, color: T.slate500, lineHeight: 1.7 }}>
        <div><strong>Y1 Comm</strong> = won premium × effective P&C rate ({(effectivePc * 100).toFixed(2)}%). Includes SMVC lift; does NOT include AIPP.</div>
        <div><strong>LTV</strong> = year-1 commission ÷ annualized lapse rate. Undiscounted geometric sum.</div>
        <div><strong>Payback (mo)</strong> = cost × 12 ÷ year-1 commission. Green ≤ 12 months, amber ≤ 24, red beyond.</div>
        <div><strong>LTV / Cost</strong> = full-lifetime return per acquisition dollar. Green ≥ 3x, amber ≥ 1x, red below.</div>
        <div style={{ marginTop: 6 }}><strong>Follow-ups deferred to a later session:</strong> per-teammate attribution on bound HHs (needs a new bound_households table linking policy → agent). Meta social-analytics sync from social_accounts to <code style={{ background: T.slate100, padding: "1px 4px", borderRadius: 3 }}>social_analytics</code> table (schema exists, sync path not wired).</div>
      </div>
    </div>
  );
}


// ─── Main Marketing Module ────────────────────────────────────
const SECTIONS = [
  { id: "overview",  label: "Overview" },
  { id: "sources",   label: "Lead Sources" },
  { id: "economics", label: "Economics" },
  { id: "everquote", label: "EverQuote" },
  { id: "refrev",    label: "Referrals & Reviews" },
  { id: "ideas",     label: "Ideas" },
  { id: "spend",     label: "Spend" },
];

export default function Marketing() {
  const vp = useViewport();
  const _pad = vp.isPhone ? "12px" : vp.isTablet ? "16px 18px" : "20px 24px";
  const now = new Date();
  const [year, setYear] = useState(now.getFullYear());
  const [quarter, setQuarter] = useState(Math.floor(now.getMonth() / 3) + 1);
  const [section, setSection] = useTabParam("tab", "overview", ["overview","refrev","sources","spend","economics","everquote","ideas"]);
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
      {section === "economics" && <EconomicsTab />}
      {section === "everquote" && <EverquoteTab />}
      {section === "refrev" && <ReferralsReviewsTab />}
      {section === "ideas" && <IdeasTab />}
      {section === "spend" && <SpendTab state={state} />}
    </div>
  );
}
