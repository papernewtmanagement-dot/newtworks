 import { useState, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import CashRegister from "./CashRegister.jsx";
import Documents from "./Documents.jsx";
import MonthlyClose from "./MonthlyClose.jsx";

// ============================================================
// BCC FINANCIALS MODULE v1.1
// Business Command Center — State Farm Agent Edition
//
// SECTIONS:
//   1. Overview        — Summary cards + revenue trend chart
//   2. P&L             — Monthly/quarterly/annual P&L
//   3. COMP_RECAP      — SF compensation detail by period
//   4. AIPP & Scorecard — Progress tracking
//   5. Payroll         — Staff payroll history
//   6. Bank Accounts   — Account balances and reconciliation
//   7. Credit & Debt   — Cards, loans, lines of credit
//   8. General Ledger  — Full transaction ledger
//
// DATA: Reads live from Supabase views/tables via useFinancialsData().
// ============================================================


// ─── Design Tokens (matches BCCApp shell) ────────────────────

import { T } from "../lib/theme.js";

const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

// ─── Live Supabase Data Hook ─────────────────────────────────
function useFinancialsData() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      try {
        const currentYear  = new Date().getFullYear();
        const currentMonth = new Date().getMonth() + 1;     // 1-12
        const quarterStart = Math.floor((currentMonth - 1) / 3) * 3 + 1;

        const [
          isRows, compRows, bankRows, ccRows, glRows,
          payrollRunsRes, payrollDetailRows,
          aippRow, scorecardRows, balanceSheetRows,
        ] = await Promise.all([
          // Income statement view
          supabase.from("v_income_statement")
            .select("account_name, account_type, amount, month, year")
            .eq("year", currentYear).order("month"),

          // SF comp recap — real schema columns
          supabase.from("comp_recap")
            .select("period_year, period_month, comp_type, comp_category, description, amount, is_aipp_eligible, is_scorecard_eligible")
            .order("period_year", { ascending: false })
            .order("period_month", { ascending: false })
            .limit(2000),   // 16+ months of twice-monthly recaps ~800 rows; cap well above row count so no period is hidden

          // Bank
          supabase.from("v_bank_balances")
            .select("account_name, current_balance:current_balance_derived, needs_review, last_entry_date"),

          // Credit
          supabase.from("v_card_balances")
            .select("account_name, current_balance:current_balance_derived, institution, needs_review, last_entry_date"),

          // GL
          supabase.from("journal_lines")
            .select(`
              debit, credit, created_at,
              journal_entries!inner ( entry_date, reference_number, description, source ),
              chart_of_accounts!inner ( account_name )
            `)
            .order("created_at", { ascending: false }).limit(50),

          // Payroll runs (header)
          supabase.from("payroll_runs")
            .select("id, pay_period_start, pay_period_end, pay_date, payroll_provider, gross_payroll, employer_taxes, net_payroll, status")
            .order("pay_date", { ascending: false }).limit(200),   // show full payroll history; YTD totals on this tab sum these rows

          // Payroll detail (per-employee)
          supabase.from("payroll_detail")
            .select("payroll_run_id, gross_pay, federal_tax, state_tax, social_security, medicare, other_deductions, net_pay, employment_type"),

          // AIPP — real schema
          supabase.from("aipp_tracking")
            .select("program_year, target_amount, earned_ytd, projected_full_year, achievement_percentage, notes")
            .order("program_year", { ascending: false }).limit(1).maybeSingle(),

          // Scorecard
          supabase.from("scorecard_tracking")
            .select("program_year, period, metric_name, target, actual, achievement_percentage, notes")
            .order("program_year", { ascending: false }).limit(20),

          // Balance Sheet — anchored to QBO 4/30/2026 opening balances + post-4/30 GL activity
          supabase.from("v_balance_sheet_anchored")
            .select("account_code, account_name, account_type, anchor_0430, activity_since_0430, balance_current"),
        ]);

        const isData = isRows.data || [];

        // Monthly chart
        const monthlyRevenue = MONTHS.map((m, i) => {
          const mo = i + 1;
          const rev = isData.filter(r => r.month === mo && r.account_type === "income").reduce((s,r) => s + parseFloat(r.amount||0), 0);
          const exp = isData.filter(r => r.month === mo && r.account_type === "expense").reduce((s,r) => s + parseFloat(r.amount||0), 0);
          return { month: m, revenue: Math.round(rev), expenses: Math.round(exp) };
        });

        // P&L line items
        const buildLines = (type) =>
          [...new Set(isData.filter(r=>r.account_type===type).map(r=>r.account_name))].map(name => {
            const rows = isData.filter(r=>r.account_name===name && r.account_type===type);
            const ytd = rows.reduce((s,r)=>s+parseFloat(r.amount||0),0);
            const mtd = rows.filter(r=>r.month===currentMonth).reduce((s,r)=>s+parseFloat(r.amount||0),0);
            const qtd = rows.filter(r=>r.month>=quarterStart && r.month<=currentMonth).reduce((s,r)=>s+parseFloat(r.amount||0),0);
            return { name, mtd: Math.round(mtd), qtd: Math.round(qtd), ytd: Math.round(ytd) };
          });

        const incomeLines  = buildLines("income");
        const expenseLines = buildLines("expense");

        const sumByPeriod = (type, predicate) =>
          isData.filter(r => r.account_type === type && predicate(r))
                .reduce((s,r) => s + parseFloat(r.amount||0), 0);

        const revYTD = sumByPeriod("income",  () => true);
        const expYTD = sumByPeriod("expense", () => true);
        const revMTD = sumByPeriod("income",  r => r.month === currentMonth);
        const expMTD = sumByPeriod("expense", r => r.month === currentMonth);
        const revQTD = sumByPeriod("income",  r => r.month >= quarterStart && r.month <= currentMonth);
        const expQTD = sumByPeriod("expense", r => r.month >= quarterStart && r.month <= currentMonth);

        // Comp recap — group rows into "periods" (e.g. "Apr 2026") and pre-format for the section
        const compRecapsRaw = compRows.data || [];
        const compRecaps = compRecapsRaw.map(r => ({
          period_year:  r.period_year,
          period_month: r.period_month,
          period_label: `${MONTHS[r.period_month-1]} ${r.period_year}`,
          comp_type:    r.comp_type,
          comp_category: r.comp_category,
          description:  r.description || `${r.comp_type} — ${r.comp_category}`,
          amount:       parseFloat(r.amount || 0),
          is_aipp_eligible: r.is_aipp_eligible,
          is_scorecard_eligible: r.is_scorecard_eligible,
        }));

        // AIPP — alias schema fields to the names AIPPSection expects
        const aippRaw = aippRow.data || null;
        const aipp = aippRaw ? {
          year:          aippRaw.program_year || currentYear,
          target:        parseFloat(aippRaw.target_amount)        || 0,
          earned:        parseFloat(aippRaw.earned_ytd)           || 0,
          projected:     parseFloat(aippRaw.projected_full_year)  || 0,
          priorYear:     0, // schema does not track prior year; show 0 unless populated
          hasData:       true,
          monthlyEarned: MONTHS.map((m,i) => {
            const mo = i + 1;
            const earned = compRecapsRaw
              .filter(r => r.period_year === currentYear && r.period_month === mo && r.is_aipp_eligible)
              .reduce((s,r) => s + parseFloat(r.amount || 0), 0);
            return { month: m, amount: Math.round(earned) };
          }),
        } : { year: currentYear, target: 0, earned: 0, projected: 0, priorYear: 0, hasData: false, monthlyEarned: MONTHS.map(m => ({month:m, amount:0})) };

        // Scorecard — alias to {metric, actual, target, pct}
        const scorecard = (scorecardRows.data || []).map(s => ({
          metric: s.metric_name,
          actual: parseFloat(s.actual || 0),
          target: parseFloat(s.target || 0),
          pct:    Math.round(parseFloat(s.achievement_percentage || 0)),
        }));

        // Payroll — combine runs + detail, grouped by run
        const detailByRun = {};
        for (const d of (payrollDetailRows.data || [])) {
          (detailByRun[d.payroll_run_id] ||= []).push(d);
        }
        const payroll = (payrollRunsRes.data || []).map(run => {
          const startStr = new Date(run.pay_period_start).toLocaleDateString("en-US", { month:"short", day:"numeric" });
          const endStr   = new Date(run.pay_period_end).toLocaleDateString("en-US", { month:"short", day:"numeric", year:"numeric" });
          const dateStr  = run.pay_date ? new Date(run.pay_date).toLocaleDateString("en-US", { month:"short", day:"numeric", year:"numeric" }) : "";
          return {
            pay_period: `${startStr} – ${endStr}`,
            pay_date:   dateStr,
            gross:      parseFloat(run.gross_payroll || 0),
            taxes:      parseFloat(run.employer_taxes || 0),
            net:        parseFloat(run.net_payroll || 0),
            status:     run.status || "paid",
            provider:   run.payroll_provider,
          };
        });

        // Credit accounts — alias to what CreditSection expects
        const creditAccounts = (ccRows.data || []).map(c => ({
          name:    c.account_name,
          balance: parseFloat(c.current_balance || 0),
          asOf:    c.last_entry_date,
          needsReview: c.needs_review,
          type:    c.account_type,
          last4:   c.account_number_last4,
          limit:   parseFloat(c.credit_limit || 0) || null,
          rate:    parseFloat(c.interest_rate || 0),
          payment: parseFloat(c.minimum_payment || 0),
          dueDay:  c.payment_due_day,
        }));

        // Balance Sheet — group anchored rows by type, with totals
        const bsRows = (balanceSheetRows.data || []).map(r => ({
          code:    r.account_code,
          name:    r.account_name,
          type:    r.account_type,
          anchor:  parseFloat(r.anchor_0430 || 0),
          activity:parseFloat(r.activity_since_0430 || 0),
          balance: parseFloat(r.balance_current || 0),
        }));
        const bsGroup = (t) => bsRows.filter(r => r.type === t).sort((a,b) => a.code.localeCompare(b.code));
        const bsSum   = (t) => bsRows.filter(r => r.type === t).reduce((s,r) => s + r.balance, 0);
        const balanceSheet = {
          assets:      bsGroup("asset"),
          liabilities: bsGroup("liability"),
          equity:      bsGroup("equity"),
          totalAssets:      Math.round(bsSum("asset")),
          totalLiabilities: Math.round(bsSum("liability")),
          totalEquity:      Math.round(bsSum("equity")),
          asOfLabel: monthYearLabel(currentMonth, currentYear),
        };

        setData({
          currentYear,
          currentMonth,
          quarterStart,
          summary: {
            revenueMTD: Math.round(revMTD), revenueQTD: Math.round(revQTD), revenueYTD: Math.round(revYTD),
            expensesMTD: Math.round(expMTD), expensesQTD: Math.round(expQTD), expensesYTD: Math.round(expYTD),
            netIncomeMTD: Math.round(revMTD - expMTD),
            netIncomeQTD: Math.round(revQTD - expQTD),
            netIncomeYTD: Math.round(revYTD - expYTD),
            priorYearYTD: 442434,
          },
          monthlyRevenue,
          pl: { income: incomeLines, expenses: expenseLines },
          compRecaps,
          aipp,
          scorecard,
          bankAccounts: (bankRows.data || []).map(b => ({
            name: b.account_name,
            balance: parseFloat(b.current_balance||0),
            asOf: b.last_entry_date,
            needsReview: b.needs_review,
            type: b.account_type,
            last4: b.account_number_last4,
            institution: b.institution,
          })),
          creditAccounts,
          glEntries: (glRows.data || []).map(g => ({
            date:        g.journal_entries?.entry_date,
            ref:         g.journal_entries?.reference_number,
            description: g.journal_entries?.description,
            source:      g.journal_entries?.source,
            account:     g.chart_of_accounts?.account_name,
            debit:       parseFloat(g.debit  || 0),
            credit:      parseFloat(g.credit || 0),
          })),
          payroll,
          balanceSheet,
        });
      } catch(e) {
        console.error("Financials load error:", e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, []);

  return { data, loading };
}


// ─── Helpers ─────────────────────────────────────────────────
const fmt = (n) => { const v = Number(n); if (!Number.isFinite(v)) return "—"; if (v === 0) return "—"; return "$" + v.toLocaleString("en-US", { minimumFractionDigits: 0 }); };
const pct  = (n, t) => t ? Math.round((n / t) * 100) : 0;
const yoy  = (curr, prior) => prior ? (((curr - prior) / prior) * 100).toFixed(1) : null;
const monthYearLabel = (monthIdx1, year) => {
  if (!monthIdx1 || !year) return "";
  return `${MONTHS[monthIdx1 - 1]} ${year}`;
};

// ─── Data Store (populated by Financials component with live data) ────────────
let MOCK = {
  currentYear: new Date().getFullYear(),
  currentMonth: new Date().getMonth() + 1,
  quarterStart: Math.floor((new Date().getMonth()) / 3) * 3 + 1,
  summary: { revenueMTD:0,revenueQTD:0,revenueYTD:0,expensesMTD:0,expensesQTD:0,expensesYTD:0,netIncomeMTD:0,netIncomeQTD:0,netIncomeYTD:0,priorYearYTD:0 },
  monthlyRevenue: Array(12).fill(0).map((_,i)=>({month:["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][i],revenue:0,expenses:0})),
  pl:{income:[],expenses:[]},
  compRecaps:[],
  aipp: { year: new Date().getFullYear(), target:0, earned:0, projected:0, priorYear:0, hasData:false, monthlyEarned: ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"].map(m=>({month:m,amount:0})) },
  scorecard: [],
  bankAccounts:[],creditAccounts:[],glEntries:[],payroll:[],
  balanceSheet:{ assets:[], liabilities:[], equity:[], totalAssets:0, totalLiabilities:0, totalEquity:0, asOfLabel:"" },
};


// ─── Shared Components ───────────────────────────────────────
const Card = ({ children, style = {} }) => (
  <div style={{
    background: T.white,
    border: `1px solid ${T.slate200}`,
    borderRadius: 12,
    padding: "16px 18px",
    ...style,
  }}>
    {children}
  </div>
);

const CardHeader = ({ title, sub, action }) => (
  <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", marginBottom: 14 }}>
    <div>
      <div style={{ fontSize: 13, fontWeight: 600, color: T.slate800 }}>{title}</div>
      {sub && <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>{sub}</div>}
    </div>
    {action}
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

const Pill = ({ children, type = "info" }) => {
  const map = {
    success: { bg: T.greenLt,  color: "#065F46" },
    warning: { bg: T.amberLt,  color: "#92400E" },
    danger:  { bg: T.redLt,    color: "#991B1B" },
    info:    { bg: T.blueLt,   color: "#1E40AF" },
    purple:  { bg: T.purpleLt, color: "#5B21B6" },
  };
  const s = map[type] || map.info;
  return (
    <span style={{
      display: "inline-flex", alignItems: "center",
      fontSize: 10, fontWeight: 600,
      padding: "3px 8px", borderRadius: 20,
      background: s.bg, color: s.color,
      whiteSpace: "nowrap",
    }}>{children}</span>
  );
};

const AskBtn = ({ context }) => (
  <button
    onClick={() => { navigator.clipboard?.writeText(context); window.open("https://claude.ai","_blank"); }}
    style={{
      display: "flex", alignItems: "center", gap: 5,
      background: T.blue, color: T.white,
      border: "none", borderRadius: 7,
      padding: "6px 12px", fontSize: 11, fontWeight: 600,
      cursor: "pointer", whiteSpace: "nowrap", flexShrink: 0,
    }}
  >
    ⚡ Ask Claude
  </button>
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

// ─── Mini Bar Chart ──────────────────────────────────────────
const MiniBarChart = ({ data }) => {
  const maxVal = Math.max(...data.map(d => Math.max(d.revenue, d.expenses)));
  const barH = 80;
  return (
    <div style={{ display: "flex", alignItems: "flex-end", gap: 3, height: barH + 24 }}>
      {data.map((d, i) => (
        <div key={i} style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", gap: 2 }}>
          <div style={{ width: "100%", display: "flex", flexDirection: "column", alignItems: "center", gap: 1, height: barH, justifyContent: "flex-end" }}>
            {d.revenue > 0 && (
              <div style={{
                width: "60%", background: T.blue, borderRadius: "2px 2px 0 0",
                height: `${maxVal ? (d.revenue / maxVal) * barH : 0}px`,
                transition: "height 0.6s ease",
              }} />
            )}
            {d.revenue === 0 && (
              <div style={{ width: "60%", background: T.slate200, borderRadius: "2px 2px 0 0", height: 3 }} />
            )}
          </div>
          <div style={{ fontSize: 9, color: T.slate400 }}>{d.month}</div>
        </div>
      ))}
    </div>
  );
};

// ─── Progress Bar ────────────────────────────────────────────
const ProgressBar = ({ value, max, color = T.blue, height = 8 }) => {
  const p = Math.min(pct(value, max), 100);
  return (
    <div style={{ height, background: T.slate100, borderRadius: height / 2, overflow: "hidden" }}>
      <div style={{
        height: "100%", width: `${p}%`,
        background: color, borderRadius: height / 2,
        transition: "width 0.7s ease",
      }} />
    </div>
  );
};

// ─── Section: Overview ───────────────────────────────────────
const OverviewSection = ({ period, setPeriod, data }) => {
  const d = data?.summary || {};
  const yoyPct = yoy(d.revenueYTD || 0, d.priorYearYTD || 0);
  const curMonthLabel = monthYearLabel(data?.currentMonth, data?.currentYear);

  // Period-correct figures
  const revenue  = period==="mtd" ? d.revenueMTD  : period==="qtd" ? d.revenueQTD  : d.revenueYTD;
  const expenses = period==="mtd" ? d.expensesMTD : period==="qtd" ? d.expensesQTD : d.expensesYTD;
  const netIncome= period==="mtd" ? d.netIncomeMTD: period==="qtd" ? d.netIncomeQTD: d.netIncomeYTD;
  const expRatio = revenue ? Math.round((expenses / revenue) * 100) + "%" : "—";

  return (
    <div>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 14 }}>
        <TabBar
          tabs={[{ id:"mtd", label:"This Month" },{ id:"qtd", label:"This Quarter" },{ id:"ytd", label:"Year to Date" }]}
          active={period}
          onChange={setPeriod}
        />
        <AskBtn context={`My agency financials — ${period.toUpperCase()}: Revenue $${revenue}, Expenses $${expenses}, Net Income $${netIncome}. YTD is up ${yoyPct}% vs prior year. Help me analyze my financial performance.`} />
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px,1fr))", gap: 10, marginBottom: 16 }}>
        <KPICard label="Revenue" value={fmt(revenue)} sub={period==="ytd"?`↑ ${yoyPct}% vs prior year`:undefined} color={T.blue} border={T.blue} />
        <KPICard label="Expenses" value={fmt(expenses)} sub="Cash basis" border={T.amber} />
        <KPICard label="Net Income" value={fmt(netIncome)} color={netIncome >= 0 ? T.green : T.red} border={netIncome >= 0 ? T.green : T.red} />
        <KPICard label="Expense Ratio" value={expRatio} sub="Target: <45%" border={T.slate200} />
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 12 }}>
        <Card>
          <CardHeader title={`Monthly revenue — ${data?.currentYear || ""}`} sub="Blue bars = revenue · Gray = no data yet" />
          <MiniBarChart data={data.monthlyRevenue} />
        </Card>

        <Card>
          <CardHeader title={`Income breakdown — ${curMonthLabel}`} />
          {(Array.isArray(data?.pl?.income) ? data.pl.income : []).filter(item => (item.mtd || 0) !== 0).map((item, i) => (
            <div key={i} style={{ marginBottom: 10 }}>
              <div style={{ display: "flex", justifyContent: "space-between", fontSize: 11, marginBottom: 3 }}>
                <span style={{ color: T.slate600 }}>{item.name}</span>
                <span style={{ fontWeight: 600, color: T.slate900 }}>{fmt(item.mtd)}</span>
              </div>
              <ProgressBar value={item.mtd || 0} max={data?.summary?.revenueMTD || 1} color={T.blue} />
            </div>
          ))}
          {(Array.isArray(data?.pl?.income) ? data.pl.income : []).filter(item => (item.mtd || 0) !== 0).length === 0 && (
            <div style={{ fontSize: 11, color: T.slate400, padding: "8px 0" }}>No income recorded yet for {curMonthLabel}.</div>
          )}
        </Card>
      </div>
    </div>
  );
};

// ─── Section: P&L ────────────────────────────────────────────
const PLSection = ({ data }) => {
  const pl = data?.pl || { income: [], expenses: [] };
  const incomeRows  = Array.isArray(pl.income)   ? pl.income   : [];
  const expenseRows = Array.isArray(pl.expenses) ? pl.expenses : [];
  const totalIncomeMTD  = incomeRows.reduce((s,r) => s + (r?.mtd || 0), 0);
  const totalExpMTD     = expenseRows.reduce((s,r) => s + (r?.mtd || 0), 0);
  const totalIncomeYTD  = incomeRows.reduce((s,r) => s + (r?.ytd || 0), 0);
  const totalExpYTD     = expenseRows.reduce((s,r) => s + (r?.ytd || 0), 0);

  const curMonthLabel = monthYearLabel(data?.currentMonth, data?.currentYear);
  const qLabel = data?.quarterStart ? `Q${Math.floor((data.quarterStart - 1) / 3) + 1} ${data?.currentYear || ""}` : "Quarter";
  const ytdLabel = `YTD ${data?.currentYear || ""}`;

  const TRow = ({ label, mtd, qtd, ytd, bold, indent, isTotal, isNeg }) => (
    <tr style={{ background: isTotal ? T.slate50 : "transparent" }}>
      <td style={{ padding: "7px 8px", fontSize: 12, color: indent ? T.slate600 : T.slate800, paddingLeft: indent ? 24 : 8, fontWeight: bold ? 600 : 400 }}>{label}</td>
      <td style={{ padding: "7px 8px", fontSize: 12, textAlign: "right", fontWeight: bold ? 600 : 400, color: isNeg ? T.red : bold ? T.slate900 : T.slate700 }}>{fmt(mtd)}</td>
      <td style={{ padding: "7px 8px", fontSize: 12, textAlign: "right", fontWeight: bold ? 600 : 400, color: isNeg ? T.red : bold ? T.slate900 : T.slate700 }}>{fmt(qtd)}</td>
      <td style={{ padding: "7px 8px", fontSize: 12, textAlign: "right", fontWeight: bold ? 600 : 400, color: isNeg ? T.red : bold ? T.slate900 : T.slate700 }}>{fmt(ytd)}</td>
    </tr>
  );

  return (
    <Card>
      <CardHeader
        title="Profit & Loss Statement"
        sub={`Cash basis · Calendar year ${data?.currentYear || ""}`}
        action={<AskBtn context={`My P&L: YTD Revenue $${totalIncomeYTD}, YTD Expenses $${totalExpYTD}, Net Income $${totalIncomeYTD - totalExpYTD}. Expense ratio ${totalIncomeYTD ? Math.round((totalExpYTD/totalIncomeYTD)*100) : 0}%. Help me analyze my profitability and identify areas to improve.`} />}
      />
      <div style={{ overflowX: "auto" }}>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead>
            <tr style={{ borderBottom: `2px solid ${T.slate200}` }}>
              <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "left" }}>Account</th>
              <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "right" }}>{curMonthLabel}</th>
              <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "right" }}>{qLabel}</th>
              <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "right" }}>{ytdLabel}</th>
            </tr>
          </thead>
          <tbody>
            <TRow label="INCOME" bold />
            {incomeRows.map((r,i) => (
              <TRow key={i} label={r.name} mtd={r.mtd} qtd={r.qtd} ytd={r.ytd} indent />
            ))}
            <TRow label="Total Income" mtd={totalIncomeMTD} qtd={incomeRows.reduce((s,r)=>s+r.qtd,0)} ytd={totalIncomeYTD} bold isTotal />

            <tr><td colSpan={4} style={{ padding: "6px 0" }} /></tr>

            <TRow label="EXPENSES" bold />
            {expenseRows.map((r,i) => (
              <TRow key={i} label={r.name} mtd={r.mtd} qtd={r.qtd} ytd={r.ytd} indent />
            ))}
            <TRow label="Total Expenses" mtd={totalExpMTD} qtd={expenseRows.reduce((s,r)=>s+r.qtd,0)} ytd={totalExpYTD} bold isTotal />

            <tr><td colSpan={4} style={{ padding: "2px 0", borderTop: `2px solid ${T.slate800}` }} /></tr>
            <TRow label="NET INCOME" mtd={totalIncomeMTD-totalExpMTD} qtd={incomeRows.reduce((s,r)=>s+r.qtd,0)-expenseRows.reduce((s,r)=>s+r.qtd,0)} ytd={totalIncomeYTD-totalExpYTD} bold isTotal />
          </tbody>
        </table>
      </div>
    </Card>
  );
};

// ─── Section: COMP_RECAP ─────────────────────────────────────
const CompRecapSection = ({ data }) => {
  const compRecaps = Array.isArray(data?.compRecaps) ? data.compRecaps : [];
  const allPeriods = [...new Set(compRecaps.map(r => r?.period_label).filter(Boolean))];
  const [period, setPeriod] = useState("");
  // Initialize period to most recent once data arrives
  useEffect(() => {
    if (allPeriods.length > 0 && !allPeriods.includes(period)) {
      setPeriod(allPeriods[0]);
    }
  }, [allPeriods.join("|")]);
  const periods  = allPeriods;
  const filtered = compRecaps.filter(r => r.period_label === period);
  const total    = filtered.reduce((s,r) => s + parseFloat(r.amount || 0), 0);
  const aippTotal = filtered.filter(r => r.is_aipp_eligible).reduce((s,r) => s + parseFloat(r.amount || 0), 0);

  return (
    <Card>
      <CardHeader
        title="SF COMP_RECAP Detail"
        sub="State Farm compensation breakdown by period"
        action={<AskBtn context={`My SF COMP_RECAP for ${period}: Total $${total}. AIPP eligible: $${aippTotal}. Help me reconcile this to my GL and confirm my AIPP calculation.`} />}
      />
      <div style={{ display: "flex", gap: 8, marginBottom: 14, flexWrap: "wrap" }}>
        {periods.map(p => (
          <button key={p} onClick={() => setPeriod(p)} style={{
            padding: "5px 12px", fontSize: 11, fontWeight: period===p ? 600 : 400,
            color: period===p ? T.white : T.slate600,
            background: period===p ? T.navy : T.white,
            border: `1px solid ${period===p ? T.navy : T.slate200}`,
            borderRadius: 6, cursor: "pointer",
          }}>{p}</button>
        ))}
      </div>

      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead>
          <tr style={{ borderBottom: `1px solid ${T.slate200}` }}>
            <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "left" }}>Compensation Type</th>
            <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "center" }}>AIPP Eligible</th>
            <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "right" }}>Amount</th>
          </tr>
        </thead>
        <tbody>
          {filtered.map((r,i) => (
            <tr key={i} style={{ borderBottom: `1px solid ${T.slate100}` }}>
              <td style={{ padding: "8px 8px", fontSize: 12, color: T.slate800 }}>{r.description}</td>
              <td style={{ padding: "8px 8px", textAlign: "center" }}>
                {r.is_aipp_eligible
                  ? <Pill type="success">AIPP</Pill>
                  : <span style={{ fontSize: 11, color: T.slate400 }}>—</span>}
              </td>
              <td style={{ padding: "8px 8px", fontSize: 12, fontWeight: 600, color: T.slate900, textAlign: "right" }}>{fmt(Math.round(r.amount))}</td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr style={{ borderTop: `2px solid ${T.slate800}` }}>
            <td style={{ padding: "8px 8px", fontSize: 12, fontWeight: 700, color: T.slate900 }}>Total</td>
            <td style={{ padding: "8px 8px", fontSize: 11, textAlign: "center", color: T.slate500 }}>AIPP: {fmt(aippTotal)}</td>
            <td style={{ padding: "8px 8px", fontSize: 13, fontWeight: 700, color: T.blue, textAlign: "right" }}>{fmt(total)}</td>
          </tr>
        </tfoot>
      </table>
    </Card>
  );
};

// ─── Section: AIPP & Scorecard ──────────────────────────────
const AIPPSection = ({ data }) => {
  const aippData = data?.aipp || {};
  const year       = aippData.year       || new Date().getFullYear();
  const target     = aippData.target     || 0;
  const earned     = aippData.earned     || 0;
  const projected  = aippData.projected  || 0;
  const priorYear  = aippData.priorYear  || 0;
  const hasAippData = !!aippData.hasData && target > 0;
  const monthlyEarned = Array.isArray(aippData.monthlyEarned) ? aippData.monthlyEarned : [];
  const scorecard    = Array.isArray(data?.scorecard) ? data.scorecard : [];
  const achievement = pct(earned, target);
  const projPct = pct(projected, target);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 12 }}>

        {/* AIPP Progress */}
        <Card>
          <CardHeader
            title={`AIPP ${year} — Annual Incentive Progress`}
            action={<AskBtn context={`AIPP ${year}: Target $${target}, Earned YTD $${earned}, Achievement ${achievement}%, Projected $${projected}, Prior Year $${priorYear}. Am I on track? What do I need to focus on?`} />}
          />
          {hasAippData ? (
            <>
              <div style={{ fontSize: 32, fontWeight: 700, color: T.green, letterSpacing: "-0.03em", marginBottom: 4 }}>
                {achievement}%
              </div>
              <div style={{ fontSize: 12, color: T.slate500, marginBottom: 12 }}>
                {fmt(earned)} earned of {fmt(target)} target
              </div>
              <ProgressBar value={earned} max={target} color={T.green} height={10} />
              <div style={{ display: "flex", justifyContent: "space-between", fontSize: 10, color: T.slate400, marginTop: 6, marginBottom: 16 }}>
                <span>Jan {year}</span><span>Dec {year}</span>
              </div>

              <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 8 }}>
                {[
                  { label: "Earned YTD",    value: fmt(earned),    color: T.green },
                  { label: "Projected",     value: fmt(projected), color: projPct >= 95 ? T.green : T.amber },
                  { label: "Prior Year",    value: fmt(priorYear), color: T.slate500 },
                ].map((s,i) => (
                  <div key={i} style={{ background: T.slate50, borderRadius: 8, padding: "10px 12px", textAlign: "center" }}>
                    <div style={{ fontSize: 10, color: T.slate500, marginBottom: 4 }}>{s.label}</div>
                    <div style={{ fontSize: 13, fontWeight: 700, color: s.color }}>{s.value}</div>
                  </div>
                ))}
              </div>

              <div style={{ marginTop: 14 }}>
                <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 8 }}>Monthly earned — {year}</div>
                <div style={{ display: "flex", gap: 6 }}>
                  {monthlyEarned.map((m,i) => (
                    <div key={i} style={{ flex: 1, background: T.blueLt, borderRadius: 6, padding: "6px 4px", textAlign: "center" }}>
                      <div style={{ fontSize: 9, color: T.slate500 }}>{m.month}</div>
                      <div style={{ fontSize: 10, fontWeight: 700, color: T.blue, marginTop: 2 }}>{fmt(m.amount)}</div>
                    </div>
                  ))}
                </div>
              </div>
            </>
          ) : (
            <div style={{ padding: "8px 0" }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: T.slate700, marginBottom: 6 }}>Awaiting AIPP program data</div>
              <div style={{ fontSize: 12, color: T.slate500, lineHeight: 1.5 }}>
                AIPP projection turns on once the {year} program-year target and producer production
                are loaded. AIPP is 5% of qualifying new P&amp;C premium issued (Auto/Fire, plus small Health),
                paid each January, for agents with 60+ months of service.
              </div>
            </div>
          )}
        </Card>

        {/* Scorecard */}
        <Card>
          <CardHeader
            title={`Scorecard Metrics — ${year}`}
            sub="Progress toward performance recognition"
            action={<AskBtn context={`My Scorecard metrics for ${year}: reviewing progress toward SF performance recognition. Help me identify which metrics need the most attention.`} />}
          />
          {scorecard.length > 0 ? (
            scorecard.map((m, i) => (
              <div key={i} style={{ marginBottom: 14 }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 4 }}>
                  <span style={{ fontSize: 12, color: T.slate700 }}>{m.metric}</span>
                  <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                    <span style={{ fontSize: 11, color: T.slate500 }}>{m.actual}/{m.target}</span>
                    <Pill type={m.pct >= 100 ? "success" : m.pct >= 75 ? "warning" : "danger"}>
                      {m.pct}%
                    </Pill>
                  </div>
                </div>
                <ProgressBar
                  value={m.actual}
                  max={m.target}
                  color={m.pct >= 100 ? T.green : m.pct >= 75 ? T.amber : T.red}
                  height={6}
                />
              </div>
            ))
          ) : (
            <div style={{ padding: "8px 0" }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: T.slate700, marginBottom: 6 }}>No Scorecard metrics loaded yet</div>
              <div style={{ fontSize: 12, color: T.slate500, lineHeight: 1.5 }}>
                Scorecard tracking populates once {year} benchmarks and current production are entered.
                Life &amp; Health production in Q3/Q4 lifts next year's Auto/Fire Scorecard multiplier.
              </div>
            </div>
          )}
        </Card>
      </div>
    </div>
  );
};

// ─── Section: Payroll ─────────────────────────────────────────
const PayrollSection = ({ data }) => {
  const ytdGross = (data.payroll || []).reduce((s,r) => s + parseFloat(r.gross || 0), 0);
  const ytdTax   = (data.payroll || []).reduce((s,r) => s + parseFloat(r.taxes || 0), 0);

  return (
    <Card>
      <CardHeader
        title="Payroll History"
        sub={`YTD Gross: ${fmt(ytdGross)} · YTD Taxes: ${fmt(ytdTax)}`}
        action={<AskBtn context={`My agency payroll YTD: Gross ${fmt(ytdGross)}, Employer taxes ${fmt(ytdTax)}. Help me review payroll expenses and identify any concerns.`} />}
      />
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead>
          <tr style={{ borderBottom: `1px solid ${T.slate200}` }}>
            {["Pay Period","Pay Date","Gross","Employer Taxes","Net Payroll","Status"].map((h,i) => (
              <th key={i} style={{ padding: "8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: i > 1 ? "right" : "left" }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {(data.payroll || []).map((r,i) => (
            <tr key={i} style={{ borderBottom: `1px solid ${T.slate100}` }}>
              <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate800 }}>{r.pay_period||r.period}</td>
              <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate600 }}>{r.pay_date||r.payDate||"-"}</td>
              <td style={{ padding: "9px 8px", fontSize: 12, fontWeight: 600, color: T.slate900, textAlign: "right" }}>{fmt(r.gross)}</td>
              <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate700, textAlign: "right" }}>{fmt(parseFloat(r.taxes||0))}</td>
              <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate700, textAlign: "right" }}>{fmt(parseFloat(r.net||0))}</td>
              <td style={{ padding: "9px 8px", textAlign: "right" }}>
                <Pill type="success">{r.status}</Pill>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </Card>
  );
};

// ─── Section: Bank Accounts ───────────────────────────────────
const BankSection = ({ data }) => {
  const bankAccounts = Array.isArray(data?.bankAccounts) ? data.bankAccounts : [];
  const totalCash = bankAccounts.reduce((s,r) => s + (r?.balance || 0), 0);
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px,1fr))", gap: 10 }}>
        {bankAccounts.map((a, i) => (
          <Card key={i}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 8 }}>
              <div style={{ fontSize: 11, fontWeight: 600, color: T.slate700 }}>{a.name}</div>
              {a.needsReview ? (
                <Pill type="warning">Review</Pill>
              ) : null}
            </div>
            <div style={{ fontSize: 24, fontWeight: 700, color: T.slate900, letterSpacing: "-0.02em" }}>
              {fmt(a.balance)}
            </div>
            <div style={{ fontSize: 10, color: T.slate400, marginTop: 4 }}>
              {a.asOf ? `As of ${a.asOf}` : "Ledger-derived balance"}
            </div>
          </Card>
        ))}
        <Card style={{ background: T.navy, border: "none" }}>
          <div style={{ fontSize: 11, fontWeight: 600, color: "rgba(255,255,255,0.7)", marginBottom: 8 }}>Total Cash Position</div>
          <div style={{ fontSize: 26, fontWeight: 700, color: T.white, letterSpacing: "-0.02em" }}>{fmt(totalCash)}</div>
          <div style={{ fontSize: 10, color: "rgba(255,255,255,0.5)", marginTop: 4 }}>All accounts combined</div>
        </Card>
      </div>
    </div>
  );
};

// ─── Section: Credit & Debt ───────────────────────────────────
const CreditSection = ({ data }) => {
  const totalDebt = (data.creditAccounts || []).reduce((s,r) => s + r.balance, 0);
  const totalAvailable = (data.creditAccounts || []).filter(a => a.limit).reduce((s,r) => s + (r.limit - r.balance), 0);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px,1fr))", gap: 10, marginBottom: 4 }}>
        <KPICard label="Total Debt Exposure" value={fmt(totalDebt)} color={T.red} border={T.red} />
        <KPICard label="Available Credit" value={fmt(totalAvailable)} color={T.green} border={T.green} />
        <KPICard label="Accounts Tracked" value={String((data.creditAccounts || []).length)} sub="Balances from ledger" border={T.amber} />
      </div>

      {(data.creditAccounts || []).map((a, i) => (
        <Card key={i}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 12 }}>
            <div>
              <div style={{ fontSize: 13, fontWeight: 600, color: T.slate800 }}>{a.name}</div>
              <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
                {a.type === "credit_card" ? "Credit Card" : a.type === "loan" ? "Loan" : "Line of Credit"}{a.rate ? ` · ${a.rate}% APR` : ""}
              </div>
              {a.needsReview ? (
                <div style={{ marginTop: 4 }}><Pill type="warning">Review</Pill></div>
              ) : null}
            </div>
            <AskBtn context={`${a.name}: Balance ${fmt(a.balance)}, Rate ${a.rate}%, Payment due on the ${a.dueDay}. Minimum payment: ${fmt(a.payment)}. Help me think about this debt.`} />
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(120px,1fr))", gap: 10 }}>
            <div>
              <div style={{ fontSize: 10, color: T.slate500, marginBottom: 2 }}>Current Balance</div>
              <div style={{ fontSize: 16, fontWeight: 700, color: T.red }}>{fmt(a.balance)}</div>
            </div>
            {a.limit && (
              <div>
                <div style={{ fontSize: 10, color: T.slate500, marginBottom: 2 }}>Available Credit</div>
                <div style={{ fontSize: 16, fontWeight: 700, color: T.green }}>{fmt(a.limit - a.balance)}</div>
              </div>
            )}
            {a.payment ? (
            <div>
              <div style={{ fontSize: 10, color: T.slate500, marginBottom: 2 }}>Min Payment</div>
              <div style={{ fontSize: 16, fontWeight: 700, color: T.amber }}>{fmt(a.payment)}</div>
            </div>
            ) : null}
            {a.dueDay ? (
            <div>
              <div style={{ fontSize: 10, color: T.slate500, marginBottom: 2 }}>Due Date</div>
              <div style={{ fontSize: 14, fontWeight: 600, color: T.slate800 }}>Day {a.dueDay}</div>
            </div>
            ) : null}
          </div>

          {a.limit && (
            <div style={{ marginTop: 10 }}>
              <div style={{ fontSize: 10, color: T.slate400, marginBottom: 4 }}>Utilization: {pct(a.balance, a.limit)}%</div>
              <ProgressBar value={a.balance} max={a.limit} color={pct(a.balance,a.limit) > 30 ? T.amber : T.green} height={6} />
            </div>
          )}
        </Card>
      ))}
    </div>
  );
};

// ─── Section: Balance Sheet ───────────────────────────────────
const BalanceSheetSection = ({ data }) => {
  const bs = data?.balanceSheet || { assets: [], liabilities: [], equity: [], totalAssets: 0, totalLiabilities: 0, totalEquity: 0, asOfLabel: "" };
  const assets = Array.isArray(bs.assets) ? bs.assets : [];
  const liabilities = Array.isArray(bs.liabilities) ? bs.liabilities : [];
  const equity = Array.isArray(bs.equity) ? bs.equity : [];
  const totalLE = (bs.totalLiabilities || 0) + (bs.totalEquity || 0);
  const ties = Math.abs((bs.totalAssets || 0) - totalLE) < 1;

  const Row = ({ name, amount, bold, indent }) => (
    <tr style={{ background: bold ? T.slate50 : "transparent" }}>
      <td style={{ padding: "7px 8px", fontSize: 12, color: indent ? T.slate600 : T.slate800, paddingLeft: indent ? 24 : 8, fontWeight: bold ? 700 : 400 }}>{name}</td>
      <td style={{ padding: "7px 8px", fontSize: 12, textAlign: "right", fontWeight: bold ? 700 : 400, color: amount < 0 ? T.red : bold ? T.slate900 : T.slate700 }}>{fmt(Math.round(amount))}</td>
    </tr>
  );

  return (
    <Card>
      <CardHeader
        title="Balance Sheet"
        sub={`Anchored to 4/30/2026 close + live GL · As of ${bs.asOfLabel || "current"}`}
        action={<AskBtn context={`My balance sheet: Total Assets ${fmt(bs.totalAssets)}, Total Liabilities ${fmt(bs.totalLiabilities)}, Total Equity ${fmt(bs.totalEquity)}. Help me understand my financial position.`} />}
      />

      {!ties && (
        <div style={{ marginBottom: 12, padding: "8px 12px", background: T.amberLt, borderRadius: 8, fontSize: 11, color: "#92400E", borderLeft: `3px solid ${T.amber}` }}>
          Note: Assets do not currently equal Liabilities + Equity. This indicates GL activity awaiting reconciliation.
        </div>
      )}

      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <tbody>
          <Row name="ASSETS" bold />
          {assets.map((r,i) => <Row key={`a${i}`} name={r.name} amount={r.balance} indent />)}
          <Row name="Total Assets" amount={bs.totalAssets} bold />

          <tr><td colSpan={2} style={{ padding: "6px 0" }} /></tr>

          <Row name="LIABILITIES" bold />
          {liabilities.map((r,i) => <Row key={`l${i}`} name={r.name} amount={r.balance} indent />)}
          <Row name="Total Liabilities" amount={bs.totalLiabilities} bold />

          <tr><td colSpan={2} style={{ padding: "6px 0" }} /></tr>

          <Row name="EQUITY" bold />
          {equity.map((r,i) => <Row key={`e${i}`} name={r.name} amount={r.balance} indent />)}
          <Row name="Total Equity" amount={bs.totalEquity} bold />

          <tr><td colSpan={2} style={{ padding: "2px 0", borderTop: `2px solid ${T.slate800}` }} /></tr>
          <Row name="Total Liabilities + Equity" amount={totalLE} bold />
        </tbody>
      </table>
    </Card>
  );
};

// ─── Section: General Ledger ──────────────────────────────────
const GLSection = ({ data }) => (
  <Card>
    <CardHeader
      title="General Ledger — Recent Entries"
      sub="Last 30 days · All accounts"
      action={<AskBtn context="I am reviewing my General Ledger recent entries. Help me verify these entries look correct and identify anything that needs attention." />}
    />
    <table style={{ width: "100%", borderCollapse: "collapse" }}>
      <thead>
        <tr style={{ borderBottom: `1px solid ${T.slate200}` }}>
          {["Date","Ref","Description","Account","Debit","Credit"].map((h,i) => (
            <th key={i} style={{ padding: "8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: i >= 4 ? "right" : "left" }}>{h}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {(Array.isArray(data?.glEntries) ? data.glEntries : []).map((r,i) => (
          <tr key={i} style={{ borderBottom: `1px solid ${T.slate100}` }}>
            <td style={{ padding: "8px", fontSize: 11, color: T.slate500 }}>{r.date}</td>
            <td style={{ padding: "8px", fontSize: 11, color: T.blue, fontFamily: "monospace" }}>{r.ref}</td>
            <td style={{ padding: "8px", fontSize: 12, color: T.slate800 }}>{r.description}</td>
            <td style={{ padding: "8px", fontSize: 11, color: T.slate500, fontFamily: "monospace" }}>{r.account}</td>
            <td style={{ padding: "8px", fontSize: 12, textAlign: "right", color: T.slate900, fontWeight: r.debit ? 500 : 400 }}>{r.debit ? fmt(r.debit) : "—"}</td>
            <td style={{ padding: "8px", fontSize: 12, textAlign: "right", color: T.green, fontWeight: r.credit ? 500 : 400 }}>{r.credit ? fmt(r.credit) : "—"}</td>
          </tr>
        ))}
      </tbody>
    </table>
  </Card>
);

// ─── CPA-Style Print Package ──────────────────────────────────
// Browser-native print: hidden on screen, shown only when printing.
const PRINT_CSS = `
@media screen { .bcc-print-package { display: none !important; } }
@media print {
  body * { visibility: hidden !important; }
  .bcc-print-package, .bcc-print-package * { visibility: visible !important; }
  .bcc-print-package { position: absolute; left: 0; top: 0; width: 100%; display: block !important; padding: 0; }
  .bcc-print-page { page-break-after: always; padding: 32px 36px; }
  .bcc-print-page:last-child { page-break-after: auto; }
  .bcc-no-print { display: none !important; }
  @page { size: letter portrait; margin: 0.5in; }
}
`;

// ─── Section: Book of Business ───────────────────────────────
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
          supabase.from("v_book_growth_summary").select("*").eq("agency_id", AGENCY_ID),
          supabase.from("v_book_snapshot_with_changes").select("*").eq("agency_id", AGENCY_ID).order("snapshot_date", { ascending: false }).limit(120),
        ]);
        if (cancelled) return;
        const summaries = Array.isArray(summaryRes?.data) ? summaryRes.data : [];
        const weeklySum = summaries.find(r => r?.cadence === "weekly");
        const monthlySum = summaries.find(r => r?.cadence === "monthly");
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

const BookAddForm = ({ onAdded }) => {
  const today = new Date().toISOString().slice(0, 10);
  const emptyForm = {
    snapshot_date: today, cadence: "weekly",
    auto_premium: "", fire_premium: "", life_premium: "", health_premium: "",
    auto_pif: "", fire_pif: "", life_pif: "", health_pif: "",
    household_count: "",
    dss_pct: "", mld_pct: "",
    auto_production_mtd: "", auto_lapse_mtd: "",
    fire_production_mtd: "", fire_lapse_mtd: "",
    life_production_mtd: "", life_lapse_mtd: "",
    count_hh_1_lob: "", count_hh_2_lob: "", count_hh_3_lob: "",
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
          .from("book_snapshot")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .eq("snapshot_date", form.snapshot_date)
          .eq("cadence", form.cadence)
          .maybeSingle();
        if (cancelled) return;
        if (error) {
          // .maybeSingle() throws on multi-row, otherwise returns null cleanly; surface but don't block
          console.warn("BookAddForm pre-fill lookup failed:", error);
          setExistingSource(null);
          return;
        }
        if (data) {
          setForm(f => ({
            ...f,
            auto_premium:        data.auto_premium        ?? "",
            fire_premium:        data.fire_premium        ?? "",
            life_premium:        data.life_premium        ?? "",
            health_premium:      data.health_premium      ?? "",
            auto_pif:            data.auto_pif            ?? "",
            fire_pif:            data.fire_pif            ?? "",
            life_pif:            data.life_pif            ?? "",
            health_pif:          data.health_pif          ?? "",
            household_count:     data.household_count     ?? "",
            dss_pct:             fmtPctForInput(data.dss_pct),
            mld_pct:             fmtPctForInput(data.mld_pct),
            auto_production_mtd: data.auto_production_mtd ?? "",
            auto_lapse_mtd:      data.auto_lapse_mtd      ?? "",
            fire_production_mtd: data.fire_production_mtd ?? "",
            fire_lapse_mtd:      data.fire_lapse_mtd      ?? "",
            life_production_mtd: data.life_production_mtd ?? "",
            life_lapse_mtd:      data.life_lapse_mtd      ?? "",
            count_hh_1_lob:      data.count_hh_1_lob      ?? "",
            count_hh_2_lob:      data.count_hh_2_lob      ?? "",
            count_hh_3_lob:      data.count_hh_3_lob      ?? "",
            notes:               data.notes               ?? "",
          }));
          setExistingSource(data.source || null);
        } else {
          setExistingSource(null);
        }
      } catch (e) {
        if (!cancelled) console.warn("BookAddForm pre-fill error:", e);
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
        auto_premium:        numOrNull(form.auto_premium),
        fire_premium:        numOrNull(form.fire_premium),
        life_premium:        numOrNull(form.life_premium),
        health_premium:      numOrNull(form.health_premium),
        auto_pif:            numOrNull(form.auto_pif),
        fire_pif:            numOrNull(form.fire_pif),
        life_pif:            numOrNull(form.life_pif),
        health_pif:          numOrNull(form.health_pif),
        household_count:     numOrNull(form.household_count),
        dss_pct:             pctOrNull(form.dss_pct),
        mld_pct:             pctOrNull(form.mld_pct),
        auto_production_mtd: numOrNull(form.auto_production_mtd),
        auto_lapse_mtd:      numOrNull(form.auto_lapse_mtd),
        fire_production_mtd: numOrNull(form.fire_production_mtd),
        fire_lapse_mtd:      numOrNull(form.fire_lapse_mtd),
        life_production_mtd: numOrNull(form.life_production_mtd),
        life_lapse_mtd:      numOrNull(form.life_lapse_mtd),
        count_hh_1_lob:      numOrNull(form.count_hh_1_lob),
        count_hh_2_lob:      numOrNull(form.count_hh_2_lob),
        count_hh_3_lob:      numOrNull(form.count_hh_3_lob),
        source: existingSource && existingSource.startsWith("sf_crm_analytics_email")
          ? "sf_crm_analytics_email_manual_review"
          : "manual_entry_bcc",
        notes: form.notes || null,
      };
      const { error } = await supabase
        .from("book_snapshot")
        .upsert(row, { onConflict: "agency_id,snapshot_date,cadence" });
      if (error) throw error;

      // Resolve any open weekly-book-snapshot alert for this Saturday
      if (form.cadence === "weekly") {
        await supabase
          .from("alerts")
          .update({ is_resolved: true, resolved_at: new Date().toISOString() })
          .eq("agency_id", AGENCY_ID)
          .eq("module_reference", `book_snapshot_weekly_alert:${form.snapshot_date}`)
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
          Auto-imported from the SF CRM Analytics email. Fields the email carried are pre-filled. Add Health, MTD production/lapse, DSS/MLD, and LOB-per-HH counts from the weekly CPR sheet, then save.
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
        {fld("health_premium", "Health premium")}
      </div>

      <div style={groupHeaderStyle}>Policies in force</div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10, marginBottom: 4 }}>
        {fld("auto_pif", "Auto PIF")}
        {fld("fire_pif", "Fire PIF")}
        {fld("life_pif", "Life PIF")}
        {fld("health_pif", "Health PIF")}
      </div>

      <div style={groupHeaderStyle}>MTD production / lapse (from CPR sheet)</div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10, marginBottom: 4 }}>
        {fld("auto_production_mtd", "Auto production MTD")}
        {fld("auto_lapse_mtd",      "Auto lapse/can MTD")}
        {fld("fire_production_mtd", "Fire production MTD")}
        {fld("fire_lapse_mtd",      "Fire lapse/can MTD")}
        {fld("life_production_mtd", "Life production MTD")}
        {fld("life_lapse_mtd",      "Life lapse/can MTD")}
      </div>

      <div style={groupHeaderStyle}>Distribution metrics</div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10, marginBottom: 4 }}>
        {fld("dss_pct", "DSS %", "number", "0.82 or 82")}
        {fld("mld_pct", "MLD %", "number", "0.64 or 64")}
        {fld("count_hh_1_lob", "# HH w/ 1 LOB")}
        {fld("count_hh_2_lob", "# HH w/ 2 LOB")}
        {fld("count_hh_3_lob", "# HH w/ 3 LOB")}
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

const BookSection = () => {
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
    return <Card><div style={{ color: T.slate500, fontSize: 12 }}>Loading book of business…</div></Card>;
  }
  if (!summary) {
    return (
      <Card>
        <div style={{ color: T.slate500, fontSize: 12, marginBottom: 12 }}>
          No snapshots yet. Add the first weekly entry below.
        </div>
        <BookAddForm onAdded={refresh} />
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
          <KPICard label="L&H Premium" value={fmt(summary.lh_premium)}
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
                    <td style={{ ...bookTdStyle, textAlign: "right" }}>{fmt(r?.lh_premium)}</td>
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
            <BookAddForm onAdded={() => { setShowAdd(false); refresh(); }} />
          </div>
        )}
      </Card>
    </div>
  );
};

const PrintTable = ({ title, sub, rows, cols }) => (
  <div style={{ marginBottom: 22 }}>
    <div style={{ fontSize: 15, fontWeight: 700, color: "#0F172A", marginBottom: 2 }}>{title}</div>
    {sub && <div style={{ fontSize: 11, color: "#64748B", marginBottom: 8 }}>{sub}</div>}
    <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 11 }}>
      <thead>
        <tr style={{ borderBottom: "2px solid #334155" }}>
          {cols.map((c,i) => (
            <th key={i} style={{ padding: "5px 6px", textAlign: i === 0 ? "left" : "right", color: "#475569", fontWeight: 600 }}>{c}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.map((r,i) => (
          <tr key={i} style={{ borderBottom: "1px solid #E2E8F0", background: r.bold ? "#F8FAFC" : "transparent" }}>
            {r.cells.map((cell,j) => (
              <td key={j} style={{ padding: "5px 6px", textAlign: j === 0 ? "left" : "right", fontWeight: r.bold ? 700 : 400, paddingLeft: (j === 0 && r.indent) ? 20 : 6, color: (typeof cell === "number" && cell < 0) ? "#EF4444" : "#1E293B" }}>
                {typeof cell === "number" ? fmt(Math.round(cell)) : cell}
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  </div>
);

const PrintPackage = ({ data, periodLabel }) => {
  const d = data || {};
  const s = d.summary || {};
  const pl = d.pl || { income: [], expenses: [] };
  const bs = d.balanceSheet || { assets: [], liabilities: [], equity: [], totalAssets: 0, totalLiabilities: 0, totalEquity: 0 };
  const today = new Date().toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" });
  const periodName = d.currentMonth ? monthYearLabel(d.currentMonth, d.currentYear) : "Current Period";

  // P&L rows (month / quarter / YTD)
  const incomeRows = (pl.income || []);
  const expenseRows = (pl.expenses || []);
  const totIncMTD = incomeRows.reduce((a,r)=>a+(r.mtd||0),0), totIncQTD = incomeRows.reduce((a,r)=>a+(r.qtd||0),0), totIncYTD = incomeRows.reduce((a,r)=>a+(r.ytd||0),0);
  const totExpMTD = expenseRows.reduce((a,r)=>a+(r.mtd||0),0), totExpQTD = expenseRows.reduce((a,r)=>a+(r.qtd||0),0), totExpYTD = expenseRows.reduce((a,r)=>a+(r.ytd||0),0);
  const qN = d.quarterStart ? Math.floor((d.quarterStart-1)/3)+1 : "";

  const plRows = [
    { cells: ["INCOME","","",""], bold: true },
    ...incomeRows.map(r => ({ cells: [r.name, r.mtd, r.qtd, r.ytd], indent: true })),
    { cells: ["Total Income", totIncMTD, totIncQTD, totIncYTD], bold: true },
    { cells: ["",""], bold: false },
    { cells: ["EXPENSES","","",""], bold: true },
    ...expenseRows.map(r => ({ cells: [r.name, r.mtd, r.qtd, r.ytd], indent: true })),
    { cells: ["Total Expenses", totExpMTD, totExpQTD, totExpYTD], bold: true },
    { cells: ["NET INCOME", totIncMTD-totExpMTD, totIncQTD-totExpQTD, totIncYTD-totExpYTD], bold: true },
  ];

  const bsTotalLE = (bs.totalLiabilities||0)+(bs.totalEquity||0);
  const bsRows = [
    { cells: ["ASSETS",""], bold: true },
    ...(bs.assets||[]).map(r => ({ cells: [r.name, r.balance], indent: true })),
    { cells: ["Total Assets", bs.totalAssets], bold: true },
    { cells: ["",""] },
    { cells: ["LIABILITIES",""], bold: true },
    ...(bs.liabilities||[]).map(r => ({ cells: [r.name, r.balance], indent: true })),
    { cells: ["Total Liabilities", bs.totalLiabilities], bold: true },
    { cells: ["",""] },
    { cells: ["EQUITY",""], bold: true },
    ...(bs.equity||[]).map(r => ({ cells: [r.name, r.balance], indent: true })),
    { cells: ["Total Equity", bs.totalEquity], bold: true },
    { cells: ["Total Liabilities + Equity", bsTotalLE], bold: true },
  ];

  const bankRows = (d.bankAccounts||[]).map(a => ({ cells: [a.name, a.balance] }));
  bankRows.push({ cells: ["Total Cash Position", (d.bankAccounts||[]).reduce((x,a)=>x+(a.balance||0),0)], bold: true });

  const creditRows = (d.creditAccounts||[]).map(a => ({ cells: [a.name, a.balance] }));
  creditRows.push({ cells: ["Total Debt Exposure", (d.creditAccounts||[]).reduce((x,a)=>x+(a.balance||0),0)], bold: true });

  return (
    <div className="bcc-print-package">
      <style>{PRINT_CSS}</style>

      {/* Cover Page */}
      <div className="bcc-print-page" style={{ textAlign: "center", paddingTop: 180 }}>
        <div style={{ fontSize: 28, fontWeight: 700, color: "#1B2B4B", marginBottom: 8 }}>Paper Newt Management LLC</div>
        <div style={{ fontSize: 18, color: "#334155", marginBottom: 40 }}>Financial Statements Package</div>
        <div style={{ fontSize: 15, color: "#475569", marginBottom: 4 }}>Period: {periodName}</div>
        <div style={{ fontSize: 12, color: "#64748B", marginBottom: 60 }}>Cash basis · Calendar year · All figures in USD</div>
        <div style={{ fontSize: 11, color: "#94A3B8" }}>Prepared {today}</div>
        <div style={{ fontSize: 11, color: "#94A3B8", marginTop: 4 }}>Business Command Center</div>
        <div style={{ marginTop: 80, fontSize: 10, color: "#94A3B8", maxWidth: 420, marginLeft: "auto", marginRight: "auto", lineHeight: 1.5 }}>
          This package contains the Profit &amp; Loss Statement, Balance Sheet, Bank Account balances,
          and Credit &amp; Debt balances. Balance Sheet is anchored to the 4/30/2026 QuickBooks close
          plus subsequent general-ledger activity.
        </div>
      </div>

      {/* P&L Page */}
      <div className="bcc-print-page">
        <PrintTable
          title="Profit & Loss Statement"
          sub={`Cash basis · ${d.currentYear || ""}`}
          cols={["Account", periodName, `Q${qN} ${d.currentYear||""}`, `YTD ${d.currentYear||""}`]}
          rows={plRows}
        />
      </div>

      {/* Balance Sheet Page */}
      <div className="bcc-print-page">
        <PrintTable
          title="Balance Sheet"
          sub={`As of ${bs.asOfLabel || periodName} · anchored to 4/30/2026 close + GL activity`}
          cols={["Account", "Balance"]}
          rows={bsRows}
        />
      </div>

      {/* Bank + Credit Page */}
      <div className="bcc-print-page">
        <PrintTable title="Bank Accounts" sub="Ledger-derived balances" cols={["Account","Balance"]} rows={bankRows} />
        <PrintTable title="Credit & Debt" sub="Outstanding balances" cols={["Account","Balance"]} rows={creditRows} />
      </div>
    </div>
  );
};

// ─── Main Financials Module ───────────────────────────────────
export default function Financials() {
  const [section, setSection] = useState("overview");
  const [period, setPeriod] = useState("mtd");
  const { data: liveData, loading } = useFinancialsData();
  if (liveData) MOCK = liveData;

  const viewSections = [
    { id: "overview",  label: "Overview"        },
    { id: "book",      label: "Book of Business"},
    { id: "pl",        label: "P&L"             },
    { id: "comp",      label: "COMP_RECAP"      },
    { id: "aipp",      label: "AIPP & Scorecard"},
    { id: "payroll",   label: "Payroll"         },
    { id: "bank",      label: "Bank Accounts"   },
    { id: "credit",    label: "Credit & Debt"   },
    { id: "balsheet",  label: "Balance Sheet"   },
    { id: "gl",        label: "General Ledger"  },
  ];
  const toolSections = [
    { id: "cashregister", label: "Cash Register" },
    { id: "documents",    label: "Documents"     },
    { id: "monthlyclose", label: "Monthly Close" },
  ];
  const sections = [...viewSections, ...toolSections];

  return (
    <div>
      {/* Module Header */}
      <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", marginBottom: 16 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900, letterSpacing: "-0.02em" }}>Financials</div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 3 }}>
            Cash basis · Calendar year · All figures in USD
          </div>
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }} className="bcc-no-print">
          <button
            onClick={() => window.print()}
            style={{
              display: "flex", alignItems: "center", gap: 5,
              background: T.white, color: T.slate700,
              border: `1px solid ${T.slate200}`, borderRadius: 7,
              padding: "6px 12px", fontSize: 11, fontWeight: 600,
              cursor: "pointer", whiteSpace: "nowrap",
            }}
          >
            🖨 Print / Save PDF
          </button>
          <AskBtn context="I am reviewing my agency financials. Help me get a complete picture of my financial health, identify any concerns, and suggest what I should focus on." />
        </div>
      </div>

      {/* Section Navigation */}
      <div style={{
        display: "flex", gap: 2, flexWrap: "wrap",
        background: T.slate100, borderRadius: 10,
        padding: 4, marginBottom: 18,
      }}>
        {sections.map((s, idx) => (
          <span key={s.id} style={{ display: "contents" }}>
            {idx === viewSections.length && (
              <div aria-hidden="true" style={{ width: 1, alignSelf: "stretch", background: T.slate300, margin: "4px 6px", opacity: 0.6 }} />
            )}
            <button onClick={() => setSection(s.id)} style={{
              padding: "7px 14px", fontSize: 12,
              fontWeight: section === s.id ? 600 : 400,
              color: section === s.id ? T.slate900 : T.slate500,
              background: section === s.id ? T.white : "transparent",
              border: "none", borderRadius: 7, cursor: "pointer",
              transition: "all 0.12s",
              boxShadow: section === s.id ? "0 1px 3px rgba(0,0,0,0.08)" : "none",
            }}>{s.label}</button>
          </span>
        ))}
      </div>

      {/* Section Content */}
      {section === "overview" && <OverviewSection period={period} setPeriod={setPeriod} data={MOCK} />}
      {section === "book"     && <BookSection />}
      {section === "pl"       && <PLSection data={MOCK} />}
      {section === "comp"     && <CompRecapSection data={MOCK} />}
      {section === "aipp"     && <AIPPSection data={MOCK} />}
      {section === "payroll"  && <PayrollSection data={MOCK} />}
      {section === "bank"     && <BankSection data={MOCK} />}
      {section === "credit"   && <CreditSection data={MOCK} />}
      {section === "balsheet" && <BalanceSheetSection data={MOCK} />}
      {section === "gl"       && <GLSection data={MOCK} />}

      {/* Operational financial tools (folded in from former top-nav items) */}
      {section === "cashregister" && <CashRegister />}
      {section === "documents"    && <Documents />}
      {section === "monthlyclose" && <MonthlyClose />}

      {/* CPA-style print package — hidden on screen, rendered for print/PDF */}
      <PrintPackage data={MOCK} periodLabel={period} />
    </div>
  );
}
