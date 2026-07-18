 import { useState, useEffect, Fragment } from "react";
import { supabase, AGENCY_ID, BUSINESS_ENTITY_ID } from "../lib/supabase.js";
import CashRegister from "./CashRegister.jsx";
import Documents from "./Documents.jsx";
import MonthlyClose from "./MonthlyClose.jsx";

// ============================================================
// Newtworks FINANCIALS MODULE v1.1
// Newtworks — State Farm Agent Edition
//
// SECTIONS:
//   1. Overview        — Summary cards + revenue trend chart + Goals feed
//   2. P&L             — Monthly/quarterly/annual P&L
//   3. Comp Recap      — SF compensation detail by period, grouped by LOB, 1H/2H checks
//   4. Payroll         — Staff payroll history (blank rows for missing weeks)
//   5. Bank Accounts   — Account balances and reconciliation
//   6. Credit & Debt   — Cards, loans, lines of credit (one row per account)
//   7. General Ledger  — Full transaction ledger
//
// DATA: Reads live from Supabase views/tables via useFinancialsData().
// ============================================================


// ─── Design Tokens (matches NewtworksApp shell) ────────────────────

import { T } from "../lib/theme.js";

import { useTabParam, handleModuleLinkClick } from "../lib/routing.jsx";
const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

// Entity hierarchy root (Peter Story / personal). Default entity for Financials
// views before Peter selects a different node. See operational_rule "Financials
// module scope: hierarchical entity tree, roll-ups at every level".
const PERSONAL_ROOT_ENTITY_ID = "b3333333-3333-3333-3333-333333333333";

// URL helper — preserve every existing query param, replace only the entity
// slot. Used by breadcrumb + children-strip anchors so right-click / cmd-click
// / middle-click open a fresh tab at the target entity view.
function urlWithEntity(entityId) {
  if (typeof window === "undefined") return "";
  const u = new URL(window.location.href);
  if (entityId && entityId !== PERSONAL_ROOT_ENTITY_ID) {
    u.searchParams.set("entity", entityId);
  } else {
    u.searchParams.delete("entity");
  }
  return u.pathname + (u.search ? u.search : "");
}

// Given the flat business_entities list and a root entity id, return a Set
// of every descendant id (inclusive of the root). Used by BankSection /
// CreditSection to filter accounts to the current subtree — Option B flat
// listing at every parent level.
function descendantsOf(rootId, allEntities) {
  if (!rootId || !Array.isArray(allEntities) || allEntities.length === 0) {
    return new Set(rootId ? [rootId] : []);
  }
  const childrenByParent = {};
  for (const e of allEntities) {
    if (e.parent_entity_id) {
      (childrenByParent[e.parent_entity_id] = childrenByParent[e.parent_entity_id] || []).push(e.id);
    }
  }
  const out = new Set([rootId]);
  const stack = [rootId];
  let safety = 0;
  while (stack.length && safety < 100) {
    const cur = stack.pop();
    for (const child of (childrenByParent[cur] || [])) {
      if (!out.has(child)) {
        out.add(child);
        stack.push(child);
      }
    }
    safety += 1;
  }
  return out;
}


// ─── Live Supabase Data Hook ─────────────────────────────────
function useFinancialsData(entity) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    async function load() {
      try {
        const currentYear  = new Date().getFullYear();
        const currentMonth = new Date().getMonth() + 1;     // 1-12
        const quarterStart = Math.floor((currentMonth - 1) / 3) * 3 + 1;

        // Latest CPR week seeds the on-time SMVC + Scorecard payload
        const { data: cprLatest } = await supabase.from("weekly_cpr_reports")
          .select("week_ending_date").eq("agency_id", AGENCY_ID)
          .order("week_ending_date", { ascending: false }).limit(1).maybeSingle();
        const s11AsOf = cprLatest?.week_ending_date || new Date().toISOString().split("T")[0];

        const [
          pnlOwnRes, pnlFullRes, compRows, bankRows, ccRows, glRows,
          payrollRunsRes, payrollDetailRows,
          aippRow, balanceSheetRows,
          growthBudgetRes, growthCeilingRes,
          bookLatestRes, bookYearStartRes, s11Res,
          childrenRes, allEntitiesRes,
        ] = await Promise.all([
          // Phase 3 (entity hierarchy) — P&L uses one-line consolidation:
          //   OWN-ONLY drives incomeLines / expenseLines for this entity.
          //   FULL-CONSOLIDATION drives Overview aggregate KPIs + monthly chart
          //   (what the entity "sees" including everything downstream) AND is
          //   the reconciliation gate: PLSection Grand Net must equal pnlFull
          //   net at every level.
          // Both RPCs return a single JSON blob to sidestep the project
          // PostgREST db_max_rows ~1000 cap that silently dropped older years
          // when we queried v_income_statement directly.
          supabase.rpc("get_pnl_history_own_only",   { p_entity_id: entity }),
          supabase.rpc("get_pnl_history_for_entity", { p_entity_id: entity }),

          // SF comp recap — real schema columns
          supabase.from("comp_recap")
            .select("period_year, period_month, comp_type, comp_category, description, amount, is_aipp_eligible, is_scorecard_eligible")
            .order("period_year", { ascending: false })
            .order("period_month", { ascending: false })
            .limit(2000),   // 16+ months of twice-monthly recaps ~800 rows; cap well above row count so no period is hidden

          // Bank — pull institution + last4 + needs_statement so BankSection can render "Institution · ••3977" and flag accounts awaiting statements.
          supabase.from("v_bank_balances")
            .select("business_entity_id, account_name, current_balance:current_balance_derived, institution, account_type, account_number_last4, needs_review, needs_statement, last_entry_date"),

          // Credit — pull the full render surface CreditSection expects: institution, last4, limit, rate, payment schedule, and last4-gap flag.
          supabase.from("v_card_balances")
            .select("business_entity_id, account_name, current_balance:current_balance_derived, institution, account_type, account_number_last4, credit_limit, interest_rate, minimum_payment, payment_due_day, needs_review, needs_last4, last_entry_date"),

          // GL — Phase 6 (entity hierarchy): fetch without hardcoded PaperNewt
          // filter; expose business_entity_id so GLSection can filter to the
          // current entity's subtree (Option B — flat listing across whole
          // subtree with per-row entity badge, same pattern as Bank/Credit/BS).
          // Bumped limit 50 → 200 so subtree filter has headroom before
          // starving the displayed list at 50.
          supabase.from("journal_lines")
            .select(`
              debit, credit, created_at, business_entity_id,
              journal_entries!inner ( entry_date, reference_number, description, source ),
              chart_of_accounts!inner ( account_name )
            `)
            .order("created_at", { ascending: false }).limit(200),

          // Payroll runs (header) — whole Financials module is PaperNewt-scoped
          supabase.from("payroll_runs")
            .select("id, pay_period_start, pay_period_end, pay_date, payroll_provider, gross_payroll, employer_taxes, net_payroll, status")
            .eq("business_entity_id", BUSINESS_ENTITY_ID)
            .order("pay_date", { ascending: false }).limit(200),   // show full payroll history; YTD totals on this tab sum these rows

          // Payroll detail (per-employee)
          supabase.from("payroll_detail")
            .select("payroll_run_id, gross_pay, federal_tax, state_tax, social_security, medicare, other_deductions, net_pay, employment_type")
            .eq("business_entity_id", BUSINESS_ENTITY_ID),

          // AIPP — real schema
          supabase.from("aipp_tracking")
            .select("program_year, target_amount, earned_ytd, projected_full_year, achievement_percentage, notes")
            .order("program_year", { ascending: false }).limit(1).maybeSingle(),

          // Balance Sheet — anchored to 6/30/2026 opening balances + post-6/30 GL activity
          // Phase 5: business_entity_id lets BalanceSheetSection filter to current
          // entity's subtree + render entity badge per row (Option B flat listing).
          supabase.from("v_balance_sheet_anchored")
            .select("account_code, account_name, account_type, opening_balance, activity_since_open, balance_current, business_entity_id"),

          // Growth budget YTD (salary ramp + licensing 6715)
          supabase.from("v_growth_budget_full_ytd")
            .select("salary_ramp_ytd_dollars, licensing_ytd_dollars, total_growth_budget_ytd_dollars, active_new_hires_ramping, total_weeks_ramping_ytd, licensing_entries_ytd")
            .eq("agency_id", AGENCY_ID).maybeSingle(),

          // Growth budget annual ceiling (10% of on-time annual gross ex-scorecard)
          supabase.rpc("get_growth_budget_ceiling", { p_agency_id: AGENCY_ID }),

          // Goals feed — latest P&C book snapshot + year-start P&C snapshot for 25%/yr growth pace
          // Filter on non-null premiums (weekly rows are seeded with counts first)
          supabase.from("agency_snapshot")
            .select("snapshot_date, auto_premium, fire_premium")
            .eq("agency_id", AGENCY_ID)
            .not("auto_premium","is",null).not("fire_premium","is",null)
            .order("snapshot_date",{ascending:false}).limit(1).maybeSingle(),
          supabase.from("agency_snapshot")
            .select("snapshot_date, auto_premium, fire_premium")
            .eq("agency_id", AGENCY_ID)
            .gte("snapshot_date", `${currentYear}-01-01`)
            .not("auto_premium","is",null).not("fire_premium","is",null)
            .order("snapshot_date",{ascending:true}).limit(1).maybeSingle(),

          // Canonical SF compute — smvc on-time %, applied %, dollar_diff, scorecard points + $ diff
          supabase.rpc("get_cpr_section_11", { p_agency_id: AGENCY_ID, p_week_ending_date: s11AsOf }),

          // Phase 3 entity nav — direct children drive the subsidiary rows in
          // PLSection + the children navigation strip below the breadcrumb.
          // allEntitiesRes drives breadcrumb (walk parent_entity_id up from
          // current entity to root, all in-memory since only 5 entities).
          supabase.rpc("get_entity_direct_children", { p_entity_id: entity }),
          supabase.from("business_entities")
            .select("id, name, entity_type, parent_entity_id")
            .eq("agency_id", AGENCY_ID),
        ]);

        // Own-only rows feed the P&L line display (incomeLines / expenseLines).
        // Full-consolidation rows feed Overview KPIs, monthly chart, and Grand
        // Net reconciliation. See operational_rule "Financials module scope"
        // for the one-line consolidation shape.
        const ownRows  = Array.isArray(pnlOwnRes?.data)  ? pnlOwnRes.data  : [];
        const fullRows = Array.isArray(pnlFullRes?.data) ? pnlFullRes.data : [];

        // pnlRows drives incomeLines / expenseLines (own-only) — variable name
        // preserved so downstream buildLines / historyYears math stays untouched.
        const pnlRows = ownRows;
        const isData = pnlRows.filter(r => r.year === currentYear);

        // Aggregate metrics (monthly chart + revenueYTD/expensesYTD/etc) use
        // FULL-CONSOLIDATION data — what this entity "sees" including every
        // descendant subtree. At root (Personal, no own JEs), aggregates come
        // entirely from subsidiaries; at leaf (Story Agency etc, no children),
        // aggregates equal own-only.
        const fullCurrentYear = fullRows.filter(r => r.year === currentYear);
        const monthlyRevenue = MONTHS.map((m, i) => {
          const mo = i + 1;
          const rev = fullCurrentYear.filter(r => r.month === mo && r.account_type === "income").reduce((s,r) => s + parseFloat(r.amount||0), 0);
          const exp = fullCurrentYear.filter(r => r.month === mo && r.account_type === "expense").reduce((s,r) => s + parseFloat(r.amount||0), 0);
          return { month: m, revenue: Math.round(rev), expenses: Math.round(exp) };
        });

        // P&L line items — includes per-month arrays for current year AND each of
        // the last 3 prior years so PLSection can slice at any grain (monthly,
        // quarterly trailing, annual trailing).
        const priorIsData = pnlRows.filter(r => r.year !== currentYear);
        // historyYears now derived from data (RPC returns all available years back to 2019).
        // Sorted ascending; used by buildLines to init perMonthByYear buckets so the annual
        // grain picker can pick any window of prior years without a re-fetch.
        const historyYears = [...new Set([...priorIsData, ...fullRows].map(r => r.year))]
          .filter(y => y < currentYear)
          .sort((a, b) => a - b);
        // buildLines keys on (section, account_name) so QBO parent categories
        // ("0001 ADMINISTRATION", "0002 TEAM", ...) group their accounts, and
        // post-6/30 journal_entries land in a "Z Post-6/30 ledger" section so
        // they surface but stay visually separate from historical prior_year_pl.
        const buildLines = (type) => {
          const keys = new Set();
          for (const r of isData)     if (r.account_type === type) keys.add(`${r.section || "Uncategorized"}||${r.account_name}`);
          for (const r of priorIsData) if (r.account_type === type) keys.add(`${r.section || "Uncategorized"}||${r.account_name}`);
          return [...keys].map(key => {
            const [section, name] = key.split("||");
            const rows      = isData.filter(r => (r.section || "Uncategorized") === section && r.account_name === name && r.account_type === type);
            const priorRows = priorIsData.filter(r => (r.section || "Uncategorized") === section && r.account_name === name && r.account_type === type);
            const perMonth = Array(12).fill(0);
            for (const r of rows) perMonth[(r.month || 1) - 1] += parseFloat(r.amount || 0);
            const perMonthByYear = {};
            for (const yr of [...historyYears, currentYear]) perMonthByYear[yr] = Array(12).fill(0);
            for (const r of priorRows) {
              if (perMonthByYear[r.year]) perMonthByYear[r.year][(r.month || 1) - 1] += parseFloat(r.amount || 0);
            }
            for (const r of rows) perMonthByYear[currentYear][(r.month || 1) - 1] += parseFloat(r.amount || 0);
            const perMonthPrior = perMonthByYear[currentYear - 1] || Array(12).fill(0);
            const ytd = rows.reduce((s,r) => s + parseFloat(r.amount || 0), 0);
            const mtd = rows.filter(r => r.month === currentMonth).reduce((s,r) => s + parseFloat(r.amount || 0), 0);
            const qtd = rows.filter(r => r.month >= quarterStart && r.month <= currentMonth).reduce((s,r) => s + parseFloat(r.amount || 0), 0);
            return {
              name,
              section,
              mtd: Math.round(mtd),
              qtd: Math.round(qtd),
              ytd: Math.round(ytd),
              perMonth:       perMonth.map(Math.round),
              perMonthPrior:  perMonthPrior.map(Math.round),
              perMonthByYear: Object.fromEntries(
                Object.entries(perMonthByYear).map(([y, arr]) => [y, arr.map(Math.round)])
              ),
            };
          });
        };

        const incomeLines  = buildLines("income");
        const expenseLines = buildLines("expense");

        // ─── Phase 3: Subsidiaries ─────────────────────────────────────────
        // For each direct child of the current entity, roll up its full-tree
        // P&L into a single per-period NET (income − expense) contribution
        // line. The synthetic line has the same shape as incomeLines /
        // expenseLines (perMonth[], perMonthByYear{}) so PLSection can reuse
        // the same columns.getValue / renderDelta machinery unchanged. At
        // leaf entities (no direct children) subsidiaries is [] and the
        // PLSection Subsidiaries block silently omits itself.
        const directChildren = Array.isArray(childrenRes?.data) ? childrenRes.data : [];
        const childPnls = directChildren.length > 0
          ? await Promise.all(
              directChildren.map(c => supabase.rpc("get_pnl_history_for_entity", { p_entity_id: c.id }))
            )
          : [];
        const subsidiaryLines = directChildren.map((c, i) => {
          const rows = Array.isArray(childPnls[i]?.data) ? childPnls[i].data : [];
          const perMonthByYear = {};
          for (const yr of [...historyYears, currentYear]) perMonthByYear[yr] = Array(12).fill(0);
          for (const r of rows) {
            if (!perMonthByYear[r.year]) continue;
            const sign = r.account_type === "income" ? 1 : (r.account_type === "expense" ? -1 : 0);
            if (sign === 0) continue;
            perMonthByYear[r.year][(r.month || 1) - 1] += sign * parseFloat(r.amount || 0);
          }
          const perMonth = (perMonthByYear[currentYear] || Array(12).fill(0)).map(Math.round);
          const perMonthPrior = (perMonthByYear[currentYear - 1] || Array(12).fill(0)).map(Math.round);
          const ytd = perMonth.slice(0, currentMonth).reduce((s,x) => s + x, 0);
          const mtd = perMonth[currentMonth - 1] || 0;
          const qtd = perMonth.slice(quarterStart - 1, currentMonth).reduce((s,x) => s + x, 0);
          return {
            entityId: c.id,
            entity_type: c.entity_type,
            is_leaf: c.is_leaf,
            name: c.name,
            section: "Subsidiaries",
            mtd, qtd, ytd,
            perMonth,
            perMonthPrior,
            perMonthByYear: Object.fromEntries(
              Object.entries(perMonthByYear).map(([y, arr]) => [y, arr.map(Math.round)])
            ),
          };
        });

        // ─── Phase 3: Entity context (breadcrumb + children strip) ────────
        // Walk parent_entity_id from the current entity up to the root using
        // the in-memory allEntities map (only 5 entities agency-wide, one
        // fetch handles all breadcrumb resolution). Breadcrumb is root-first
        // so the UI can render "Peter Story → PaperNewt LLC → [current]".
        const allEntities = Array.isArray(allEntitiesRes?.data) ? allEntitiesRes.data : [];
        const entitiesById = Object.fromEntries(allEntities.map(e => [e.id, e]));
        const breadcrumb = [];
        {
          let safety = 0;
          let cur = entitiesById[entity];
          while (cur && safety < 20) {
            breadcrumb.unshift({ id: cur.id, name: cur.name, entity_type: cur.entity_type });
            cur = cur.parent_entity_id ? entitiesById[cur.parent_entity_id] : null;
            safety += 1;
          }
        }

        // Aggregate KPIs (revenueMTD/QTD/YTD, expensesMTD/QTD/YTD) sum against
        // FULL-CONSOLIDATION so the numbers reflect what this entity sees at
        // every level. Own-only would zero out at parent nodes with no direct
        // JEs (e.g. Personal today shows $0 revenue since everything's stamped
        // on the PaperNewt child).
        const sumByPeriod = (type, predicate) =>
          fullCurrentYear.filter(r => r.account_type === type && predicate(r))
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

        // AIPP — alias schema fields for the Goals feed's on-time projection row
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

        // Payroll — combine runs + detail, grouped by run
        const detailByRun = {};
        for (const d of (payrollDetailRows.data || [])) {
          (detailByRun[d.payroll_run_id] ||= []).push(d);
        }
        // Postgres `date` columns arrive as bare YYYY-MM-DD. `new Date(...)` parses
        // that as UTC midnight, which renders one day earlier in Central Time (Fri pay
        // date shows as Thu). Append "T00:00:00" so JS parses it as local midnight.
        const parseLocalDate = (iso) => (typeof iso === "string" && /^\d{4}-\d{2}-\d{2}$/.test(iso))
          ? new Date(iso + "T00:00:00")
          : new Date(iso);
        const payroll = (payrollRunsRes.data || []).map(run => {
          const startStr = parseLocalDate(run.pay_period_start).toLocaleDateString("en-US", { month:"short", day:"numeric" });
          const endStr   = parseLocalDate(run.pay_period_end).toLocaleDateString("en-US", { month:"short", day:"numeric", year:"numeric" });
          const dateStr  = run.pay_date ? parseLocalDate(run.pay_date).toLocaleDateString("en-US", { month:"short", day:"numeric", year:"numeric" }) : "";
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
          needsLast4:  c.needs_last4,
          institution: c.institution,
          type:    c.account_type,
          last4:   c.account_number_last4,
          limit:   parseFloat(c.credit_limit || 0) || null,
          rate:    parseFloat(c.interest_rate || 0),
          payment: parseFloat(c.minimum_payment || 0),
          dueDay:  c.payment_due_day,
          businessEntityId: c.business_entity_id,     // Phase 4: entity badge + subtree filter
        }));

        // Goals feed pace computation
        // ---------------------------------
        // Statuses use the Dashboard "always up" scale so this matches the Dashboard widget:
        //   >= 90 green / 75-89 amber / < 75 red. Labels: Ahead / On Pace / Close / Behind / Off Pace.
        // Ratings live in the rendering component; here we just supply pace_pct + labels.
        const goalsPace = { pc: null, cc: null, smvc: null, aipp: null };
        try {
          const book   = bookLatestRes?.data || null;
          const bookYs = bookYearStartRes?.data || null;
          if (book && bookYs) {
            const ysPCPrem  = (parseFloat(bookYs.auto_premium)||0) + (parseFloat(bookYs.fire_premium)||0);
            const curPCPrem = (parseFloat(book.auto_premium)||0)   + (parseFloat(book.fire_premium)||0);
            const netYTD    = curPCPrem - ysPCPrem;
            const tgtGain   = ysPCPrem * 0.25;
            const now       = new Date();
            const ysDate    = new Date(bookYs.snapshot_date + "T00:00:00Z");
            const bookDate  = new Date(book.snapshot_date   + "T00:00:00Z");
            const effEnd    = bookDate < now ? bookDate : now;
            const daysInWin = Math.max(1, Math.floor((effEnd - ysDate) / 86400000));
            const annualGain= netYTD * (365 / daysInWin);
            const otPct     = ysPCPrem > 0 ? (annualGain / ysPCPrem) * 100 : 0;
            const pace_pct  = otPct > 0 ? (otPct / 25) * 100 : 0;
            const fmtUsd = (n) => `$${Math.round(n).toLocaleString()}`;
            const fmtUsdSigned = (n) => `${n>=0?"+":"−"}$${Math.abs(Math.round(n)).toLocaleString()}`;
            goalsPace.pc = {
              current_label: fmtUsdSigned(annualGain),
              target_label:  `+${fmtUsd(tgtGain)}`,
              sub: `${otPct.toFixed(1)}% / 25%`,
              pace_pct,
            };
          }
        } catch (e) { /* swallow */ }

        const s11 = s11Res?.data || null;
        try {
          if (s11?.scorecard_bonus?.computed_breakdown?.points_breakdown) {
            const pb = s11.scorecard_bonus.computed_breakdown.points_breakdown;
            const autoBest = parseFloat(pb.auto_best) || 0;
            const fireBest = parseFloat(pb.fire_best) || 0;
            const fsPts    = parseFloat(pb.fs_credits) || 0;
            const ccTotal  = autoBest + fireBest + fsPts;
            const dollarDiff = parseFloat(s11.scorecard_bonus.dollar_diff) || 0;
            const dSign = dollarDiff >= 0 ? "+" : "−";
            const dAbs = `$${Math.abs(Math.round(dollarDiff)).toLocaleString()}`;
            goalsPace.cc = {
              current_label: `${Math.round(ccTotal)} pts`,
              target_label:  `400 pts`,
              sub: `Auto ${Math.round(autoBest)} · Fire ${Math.round(fireBest)} · FS ${Math.round(fsPts)} · vs last yr ${dSign}${dAbs}`,
              pace_pct: (ccTotal / 400) * 100,
            };
          }
          if (s11?.smvc?.on_time != null) {
            const otPct     = (parseFloat(s11.smvc.on_time) || 0) * 100;
            const appPct    = (parseFloat(s11.smvc.applied) || 0) * 100;
            const dollarDiff= parseFloat(s11.smvc.dollar_diff) || 0;
            const tgtSmvc   = 2.70;
            const dSign = dollarDiff >= 0 ? "+" : "−";
            const dAbs = `$${Math.abs(Math.round(dollarDiff)).toLocaleString()}`;
            goalsPace.smvc = {
              current_label: `${otPct.toFixed(2)}%`,
              target_label:  `${tgtSmvc.toFixed(2)}%`,
              sub: `Currently applied ${appPct.toFixed(2)}% · pace ${dSign}${dAbs} vs applied`,
              pace_pct: tgtSmvc > 0 ? (otPct / tgtSmvc) * 100 : 0,
            };
          }
        } catch (e) { /* swallow */ }

        try {
          if (aipp && aipp.hasData && aipp.target > 0) {
            const projPct = (aipp.projected / aipp.target) * 100;
            goalsPace.aipp = {
              current_label: fmt(aipp.projected),
              target_label:  fmt(aipp.target),
              sub: `${Math.round((aipp.earned / aipp.target) * 100)}% earned YTD · ${fmt(aipp.earned)} of ${fmt(aipp.target)}`,
              pace_pct: projPct,
            };
          }
        } catch (e) { /* swallow */ }

        // Balance Sheet — group anchored rows by type, with totals
        // Phase 5: preserve business_entity_id so BalanceSheetSection can filter
        // to current subtree + render entity badge per row (same Option B flat
        // listing pattern as Bank/Credit — Phase 4). Whole-agency totals still
        // computed here for MOCK compatibility; section recomputes from filtered
        // rows when an entity subtree filter is active.
        const bsRows = (balanceSheetRows.data || []).map(r => ({
          code:    r.account_code,
          name:    r.account_name,
          type:    r.account_type,
          anchor:  parseFloat(r.opening_balance || 0),
          activity:parseFloat(r.activity_since_open || 0),
          balance: parseFloat(r.balance_current || 0),
          businessEntityId: r.business_entity_id,
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

        // Owner Profit Pace — quarterly margin computation against +1pp/quarter goal.
        // priorIsData is the own-only P&L rows for years !== currentYear (defined above
        // at line 234). Prior code destructured priorIsRows from Promise.all; phase 3
        // rename to pnlOwnRes/pnlFullRes dropped that binding but this consumer was
        // missed, causing a ReferenceError that swallowed the whole hook.
        const priorYearIS = Array.isArray(priorIsData) ? priorIsData : [];
        const quarterMargin = (yr, q) => {
          const rows = yr === currentYear ? isData : priorYearIS;
          const months = [q*3-2, q*3-1, q*3];
          const rev = rows.filter(r => months.includes(r.month) && r.account_type === "income")
            .reduce((s,r) => s + parseFloat(r.amount||0), 0);
          const exp = rows.filter(r => months.includes(r.month) && r.account_type === "expense")
            .reduce((s,r) => s + parseFloat(r.amount||0), 0);
          return rev > 0
            ? { year: yr, quarter: q, revenue: rev, expenses: exp, margin: ((rev - exp) / rev) * 100 }
            : null;
        };
        const curQ = Math.ceil(currentMonth / 3);
        let lastClosedYear, lastClosedQ, priorClosedYear, priorClosedQ;
        if (curQ === 1) {
          lastClosedYear  = currentYear - 1; lastClosedQ  = 4;
          priorClosedYear = currentYear - 1; priorClosedQ = 3;
        } else {
          lastClosedYear = currentYear; lastClosedQ = curQ - 1;
          if (curQ === 2) { priorClosedYear = currentYear - 1; priorClosedQ = 4; }
          else            { priorClosedYear = currentYear;     priorClosedQ = curQ - 2; }
        }
        const opLatest = quarterMargin(lastClosedYear, lastClosedQ);
        const opPrior  = quarterMargin(priorClosedYear, priorClosedQ);
        // Trailing 4 closed quarters for sparkline-style trend
        const trail = [];
        {
          let y = lastClosedYear, q = lastClosedQ;
          for (let i = 0; i < 4; i++) {
            const m = quarterMargin(y, q);
            if (m) trail.unshift(m);
            q -= 1; if (q < 1) { q = 4; y -= 1; }
          }
        }
        const ownerProfit = {
          latest: opLatest,
          prior:  opPrior,
          delta:  (opLatest && opPrior) ? (opLatest.margin - opPrior.margin) : null,
          target_delta: 1.0,   // +1pp per quarter goal
          trail,
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
          ownerProfit,
          monthlyRevenue,
          pl: { income: incomeLines, expenses: expenseLines, subsidiaries: subsidiaryLines },
          entityContext: { currentEntityId: entity, breadcrumb, directChildren, allEntities },
          compRecaps,
          aipp,
          goalsPace,
          bankAccounts: (bankRows.data || []).map(b => ({
            name: b.account_name,
            balance: parseFloat(b.current_balance||0),
            asOf: b.last_entry_date,
            needsReview: b.needs_review,
            needsStatement: b.needs_statement,
            type: b.account_type,
            last4: b.account_number_last4,
            institution: b.institution,
            businessEntityId: b.business_entity_id,   // Phase 4: entity badge + subtree filter
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
            businessEntityId: g.business_entity_id,   // Phase 6: subtree filter + entity badge
          })),
          payroll,
          balanceSheet,
          growthBudget: (() => {
            const gb = growthBudgetRes?.data || {};
            const ceiling = growthCeilingRes?.data || {};
            const ytd = parseFloat(gb.total_growth_budget_ytd_dollars || 0);
            const ceil = parseFloat(ceiling.ceiling_annual || 0);
            return {
              salary_ramp_ytd:   parseFloat(gb.salary_ramp_ytd_dollars || 0),
              licensing_ytd:     parseFloat(gb.licensing_ytd_dollars || 0),
              total_ytd:         ytd,
              ceiling_annual:    ceil,
              utilization_pct:   ceil > 0 ? (ytd / ceil) * 100 : 0,
              new_hires_ramping: parseInt(gb.active_new_hires_ramping || 0, 10),
              weeks_ramping_ytd: parseFloat(gb.total_weeks_ramping_ytd || 0),
              licensing_entries: parseInt(gb.licensing_entries_ytd || 0, 10),
              anchor_date:       ceiling.comp_anchor_date,
              annualization:     parseFloat(ceiling.annualization_factor || 0),
            };
          })(),
        });
      } catch(e) {
        console.error("Financials load error:", e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [reloadKey, entity]);

  return { data, loading, reload: () => setReloadKey(k => k + 1) };
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
  goalsPace: { pc:null, cc:null, smvc:null, aipp:null },
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
  <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", marginBottom: 14, flexWrap: "wrap", gap: 8 }}>
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

// ─── Owner Profit Pace Card (standing +1pp/quarter goal) ─────
const OwnerProfitPaceCard = ({ data }) => {
  const op = data?.ownerProfit;
  if (!op || !op.latest) {
    return (
      <Card>
        <CardHeader title="Owner Profit Pace" sub="+1pp per quarter — standing goal" />
        <div style={{ fontSize: 11, color: T.slate400, padding: "8px 0" }}>
          No closed-quarter data yet. Margin pace will show once at least one quarter is complete.
        </div>
      </Card>
    );
  }
  const { latest, prior, delta, trail } = op;
  const statusColor = (d) => {
    if (d == null)  return T.slate400;
    if (d >= 1.0)   return T.green;
    if (d >= 0)     return T.amber;
    return T.red;
  };
  const statusLabel = (d) => {
    if (d == null) return "—";
    if (d >= 2.0)  return "Ahead";
    if (d >= 1.0)  return "On Pace";
    if (d >= 0)    return "Behind";
    return "Off Pace";
  };
  const c = statusColor(delta);
  const sign = (n) => n >= 0 ? `+${n.toFixed(2)}` : n.toFixed(2);
  const targetLatestMargin = prior ? prior.margin + 1.0 : null;
  return (
    <Card>
      <CardHeader
        title="Owner Profit Pace"
        sub={`+1pp/quarter standing goal${targetLatestMargin != null ? ` · target Q${latest.quarter} ${latest.year}: ${targetLatestMargin.toFixed(1)}%` : ""}`}
      />
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))", gap: 12, marginBottom: 10 }}>
        <div>
          <div style={{ fontSize: 10, color: T.slate500, fontWeight: 600, marginBottom: 4, letterSpacing: "0.04em" }}>LATEST CLOSED QUARTER</div>
          <div style={{ fontSize: 26, fontWeight: 800, color: latest.margin >= 0 ? T.green : T.red }}>{latest.margin.toFixed(1)}%</div>
          <div style={{ fontSize: 10, color: T.slate500 }}>Q{latest.quarter} {latest.year} · {fmt(Math.round(latest.revenue))} rev</div>
        </div>
        {prior && (
          <div>
            <div style={{ fontSize: 10, color: T.slate500, fontWeight: 600, marginBottom: 4, letterSpacing: "0.04em" }}>PRIOR QUARTER</div>
            <div style={{ fontSize: 26, fontWeight: 800, color: prior.margin >= 0 ? T.green : T.red }}>{prior.margin.toFixed(1)}%</div>
            <div style={{ fontSize: 10, color: T.slate500 }}>Q{prior.quarter} {prior.year} · {fmt(Math.round(prior.revenue))} rev</div>
          </div>
        )}
        <div>
          <div style={{ fontSize: 10, color: T.slate500, fontWeight: 600, marginBottom: 4, letterSpacing: "0.04em" }}>DELTA vs PRIOR</div>
          <div style={{ fontSize: 26, fontWeight: 800, color: c }}>{delta != null ? `${sign(delta)} pp` : "—"}</div>
          <div style={{ display: "inline-block", fontSize: 10, fontWeight: 700, color: c, padding: "2px 9px", borderRadius: 10, background: `${c}18`, marginTop: 2 }}>{statusLabel(delta)}</div>
        </div>
      </div>
      {trail && trail.length > 1 && (
        <div style={{ marginTop: 10, paddingTop: 10, borderTop: `1px dashed ${T.slate200}` }}>
          <div style={{ fontSize: 10, color: T.slate500, fontWeight: 600, marginBottom: 6, letterSpacing: "0.04em", textTransform: "uppercase" }}>Trailing Closed Quarters</div>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            {trail.map((t, i) => (
              <div key={i} style={{ padding: "5px 9px", borderRadius: 8, background: t.margin >= 0 ? T.greenLt : T.redLt, border: `1px solid ${t.margin >= 0 ? T.green + "40" : T.red + "40"}`, fontSize: 11 }}>
                <span style={{ color: T.slate600, fontWeight: 600 }}>Q{t.quarter} {String(t.year).slice(-2)}: </span>
                <span style={{ color: t.margin >= 0 ? T.green : T.red, fontWeight: 700 }}>{t.margin.toFixed(1)}%</span>
              </div>
            ))}
          </div>
        </div>
      )}
      <div style={{ fontSize: 10, color: T.slate400, marginTop: 10 }}>
        Source: v_income_statement quarterly aggregates · Goal: each quarter's net margin ≥ prior quarter + 1pp
      </div>
    </Card>
  );
};

// ─── Goals Feed Card (mirrors Dashboard's Standing Goals widget) ──
// Rows: P&C Growth 25%/yr · Champions Circle 400 pts · SMVC 2.70% · AIPP on-time
const GoalsFeedCard = ({ data }) => {
  const g = data?.goalsPace || {};
  const statusColor = (p) => {
    if (p == null) return T.slate400;
    if (p >= 90)   return T.green;
    if (p >= 75)   return T.amber;
    return T.red;
  };
  const statusLabel = (p) => {
    if (p == null) return "—";
    if (p >= 110)  return "Ahead";
    if (p >= 100)  return "On Pace";
    if (p >= 90)   return "Close";
    if (p >= 75)   return "Behind";
    return "Off Pace";
  };
  const Row = ({ icon, title, current, target, sub, pacePct }) => {
    const c = statusColor(pacePct);
    return (
      <div style={{padding:"11px 0", borderBottom:`1px solid ${T.slate100}`}}>
        <div style={{display:"flex", justifyContent:"space-between", alignItems:"baseline", marginBottom:5, gap:8, flexWrap:"wrap"}}>
          <div style={{display:"flex", alignItems:"center", gap:8, fontSize:12, fontWeight:700, color:T.slate800, minWidth:0, flex:1}}>
            <span style={{fontSize:15}}>{icon}</span>
            <span style={{overflow:"hidden", textOverflow:"ellipsis"}}>{title}</span>
          </div>
          <div style={{fontSize:10, fontWeight:700, color:c, padding:"2px 9px", borderRadius:10, background:`${c}18`, flexShrink:0}}>{statusLabel(pacePct)}</div>
        </div>
        <div style={{display:"flex", justifyContent:"space-between", alignItems:"baseline", marginBottom:6, gap:8, flexWrap:"wrap"}}>
          <div style={{fontSize:15, fontWeight:800, color:T.slate900}}>
            {current || "—"}<span style={{fontSize:11, fontWeight:500, color:T.slate500}}> / {target || "—"}</span>
          </div>
          {sub && <div style={{fontSize:10, color:T.slate500, textAlign:"right", maxWidth:"100%"}}>{sub}</div>}
        </div>
        <ProgressBar value={Math.max(0, Math.min(pacePct||0, 100))} max={100} color={c} height={6} />
      </div>
    );
  };
  return (
    <Card>
      <CardHeader title="Goals — On-Time Pace" sub="From the Dashboard goals feed · profit pace above · numbers refresh with each CPR" />
      <Row icon="📈" title="P&C Premium Growth (25%/yr)"     current={g.pc?.current_label}   target={g.pc?.target_label}   sub={g.pc?.sub}   pacePct={g.pc?.pace_pct} />
      <Row icon="🏆" title="Champions Circle (400 Scorecard pts)" current={g.cc?.current_label}   target={g.cc?.target_label}   sub={g.cc?.sub}   pacePct={g.cc?.pace_pct} />
      <Row icon="📊" title="SMVC (target 2.70%)"             current={g.smvc?.current_label} target={g.smvc?.target_label} sub={g.smvc?.sub} pacePct={g.smvc?.pace_pct} />
      <Row icon="💰" title="AIPP — On-Time Projection"       current={g.aipp?.current_label} target={g.aipp?.target_label} sub={g.aipp?.sub} pacePct={g.aipp?.pace_pct} />
    </Card>
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
      {/* Owner Profit Pace — standing +1pp/quarter goal (independent of period selector) */}
      <div style={{ marginBottom: 14 }}>
        <OwnerProfitPaceCard data={data} />
      </div>

      {/* Goals feed — P&C growth, Champions Circle, SMVC, AIPP on-time */}
      <div style={{ marginBottom: 14 }}>
        <GoalsFeedCard data={data} />
      </div>

      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 14 }}>
        <TabBar
          tabs={[{ id:"mtd", label:"This Month" },{ id:"qtd", label:"This Quarter" },{ id:"ytd", label:"Year to Date" }]}
          active={period}
          onChange={setPeriod}
        />
        
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

        {/* Growth Budget Utilization — new-hire salary ramp + licensing 6715 vs 10% ceiling of on-time annual gross ex-Scorecard */}
        {data?.growthBudget && (
          <Card>
            <CardHeader
              title="Growth Budget — YTD"
              sub={`Ramp cost + licensing vs ceiling (10% of on-time annual gross ex-Scorecard)`}
            />
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginBottom: 10 }}>
              <div>
                <div style={{ fontSize: 10, color: T.slate500, marginBottom: 2 }}>Spent YTD</div>
                <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>{fmt(data.growthBudget.total_ytd)}</div>
              </div>
              <div>
                <div style={{ fontSize: 10, color: T.slate500, marginBottom: 2 }}>Annual Ceiling</div>
                <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>{fmt(data.growthBudget.ceiling_annual)}</div>
              </div>
            </div>
            <div style={{ marginBottom: 10 }}>
              <div style={{ display: "flex", justifyContent: "space-between", fontSize: 11, marginBottom: 3 }}>
                <span style={{ color: T.slate600 }}>Utilization</span>
                <span style={{ fontWeight: 600, color: data.growthBudget.utilization_pct > 100 ? T.red : data.growthBudget.utilization_pct > 80 ? T.amber : T.green }}>
                  {data.growthBudget.utilization_pct.toFixed(1)}%
                </span>
              </div>
              <ProgressBar
                value={data.growthBudget.total_ytd}
                max={data.growthBudget.ceiling_annual || 1}
                color={data.growthBudget.utilization_pct > 100 ? T.red : data.growthBudget.utilization_pct > 80 ? T.amber : T.green}
              />
            </div>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, fontSize: 11, color: T.slate600 }}>
              <div>
                <div style={{ color: T.slate500, marginBottom: 2 }}>Salary Ramp</div>
                <div style={{ fontWeight: 600, color: T.slate900 }}>{fmt(data.growthBudget.salary_ramp_ytd)}</div>
                <div style={{ fontSize: 10, color: T.slate400 }}>{data.growthBudget.new_hires_ramping} ramping · {data.growthBudget.weeks_ramping_ytd} weeks</div>
              </div>
              <div>
                <div style={{ color: T.slate500, marginBottom: 2 }}>Licensing (6715)</div>
                <div style={{ fontWeight: 600, color: T.slate900 }}>{fmt(data.growthBudget.licensing_ytd)}</div>
                <div style={{ fontSize: 10, color: T.slate400 }}>{data.growthBudget.licensing_entries} entries</div>
              </div>
            </div>
          </Card>
        )}
      </div>
    </div>
  );
};

// ─── Section: P&L ────────────────────────────────────────────
// Grain toggle:
//   Monthly   — Jan..current-month + YTD, chronological left→right
//   Quarterly — last 3 completed quarters + current QTD (partial) + YTD
//   Annual    — last 3 completed years + current YTD (partial)
// EVERY period column has a paired Δ sub-column showing YoY % change vs the
// same period one year prior. Single-row header (parent label spans both the
// $ and Δ cells).
// % of income checkbox adds a per-cell percentage next to each dollar.
// Non-completed periods carry a "(partial)" tag. Partial periods compare
// same-partial slice YoY (e.g. YTD 2026 through Jul vs Jan–Jul 2025).
// ─── PLDrillPanel: side panel showing every txn behind a P&L cell/row ────
// Fetches from RPC public.pnl_drill_transactions. Supports inline edit
// (reclassify account, edit description, edit date) + delete for both
// live journal_entries/journal_lines and prior_year_pl imports.
// RLS admin-write policies on those three tables shipped alongside this
// component (migration: pnl_drill_editable).
const _drillDateFmt = (d) => {
  try {
    const [y, m, day] = String(d).split("T")[0].split("-");
    return `${MONTHS[Number(m) - 1]} ${Number(day)}, ${y}`;
  } catch { return String(d); }
};
const _drillBtn = { padding: "4px 10px", fontSize: 11, background: "#fff", border: `1px solid ${T.slate200}`, borderRadius: 5, color: T.slate700, cursor: "pointer" };
const _drillBtnPrimary = { padding: "4px 10px", fontSize: 11, background: T.slate800, border: `1px solid ${T.slate800}`, borderRadius: 5, color: "#fff", cursor: "pointer", fontWeight: 500 };
const _drillBtnDanger = { padding: "4px 10px", fontSize: 11, background: "#fff", border: `1px solid #fca5a5`, borderRadius: 5, color: "#b91c1c", cursor: "pointer" };
const _drillLabel = { fontSize: 11, fontWeight: 500, color: T.slate600, display: "flex", flexDirection: "column", gap: 3 };
const _drillInput = { padding: "6px 8px", fontSize: 12, border: `1px solid ${T.slate200}`, borderRadius: 5, color: T.slate800, background: "#fff" };

const PLDrillPanel = ({ ctx, onClose, onDataChanged }) => {
  const [rows, setRows]         = useState([]);
  const [loading, setLoading]   = useState(true);
  const [error, setError]       = useState(null);
  const [editingKey, setEditingKey] = useState(null);
  const [editDraft, setEditDraft]   = useState({});
  const [saving, setSaving]     = useState(false);
  const [coaOptions, setCoaOptions] = useState([]);

  const rowKey = (r) => `${r.source}-${r.je_id || r.pyp_id || "?"}-${r.line_id || ""}`;

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const { data, error } = await supabase.rpc("pnl_drill_transactions", {
        p_account_name: ctx.accountName,
        p_section:      ctx.section,
        p_account_type: ctx.accountType,
        p_from_date:    ctx.fromDate,
        p_to_date:      ctx.toDate,
      });
      if (error) throw error;
      setRows(data || []);
    } catch (e) {
      console.error("PLDrillPanel load error:", e);
      setError(e.message || String(e));
    } finally {
      setLoading(false);
    }
  };

  const loadCoaOptions = async () => {
    try {
      const { data } = await supabase.from("chart_of_accounts")
        .select("id, account_code, account_name, account_type")
        .eq("account_type", ctx.accountType)
        .eq("is_active", true)
        .order("account_code");
      setCoaOptions(data || []);
    } catch (e) {
      console.error("PLDrillPanel COA load error:", e);
    }
  };

  useEffect(() => {
    load();
    loadCoaOptions();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ctx.accountName, ctx.section, ctx.accountType, ctx.fromDate, ctx.toDate]);

  // ESC key closes the panel
  useEffect(() => {
    const onKey = (e) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const startEdit = (row) => {
    setEditingKey(rowKey(row));
    setEditDraft({
      account_id:   row.account_id,
      description:  row.description || "",
      entry_date:   String(row.entry_date).split("T")[0],
      account_name: row.account_name || "",
    });
  };

  const cancelEdit = () => { setEditingKey(null); setEditDraft({}); };

  const saveEdit = async (row) => {
    setSaving(true);
    try {
      if (row.source === "journal") {
        const jlUpdates = {};
        if (editDraft.account_id && editDraft.account_id !== row.account_id) {
          jlUpdates.account_id = editDraft.account_id;
        }
        if ((editDraft.description || null) !== (row.description || null)) {
          jlUpdates.description = editDraft.description || null;
        }
        if (Object.keys(jlUpdates).length > 0) {
          const { data, error } = await supabase.from("journal_lines")
            .update(jlUpdates).eq("id", row.line_id).select("id");
          if (error) throw error;
          if (!data || data.length === 0) throw new Error("Journal line update returned no rows (RLS?)");
        }
        const jeUpdates = {};
        if (editDraft.entry_date && editDraft.entry_date !== String(row.entry_date).split("T")[0]) {
          jeUpdates.entry_date = editDraft.entry_date;
        }
        if (Object.keys(jeUpdates).length > 0) {
          const { data, error } = await supabase.from("journal_entries")
            .update(jeUpdates).eq("id", row.je_id).select("id");
          if (error) throw error;
          if (!data || data.length === 0) throw new Error("Journal entry update returned no rows (RLS?)");
        }
      } else if (row.source === "prior_year_pl") {
        const pypUpdates = {};
        if (editDraft.account_name && editDraft.account_name !== row.account_name) {
          pypUpdates.account_name = editDraft.account_name;
        }
        if (editDraft.entry_date && editDraft.entry_date !== String(row.entry_date).split("T")[0]) {
          const parts = editDraft.entry_date.split("-");
          pypUpdates.period_year  = Number(parts[0]);
          pypUpdates.period_month = Number(parts[1]);
          pypUpdates.period_start = editDraft.entry_date;
        }
        if (Object.keys(pypUpdates).length > 0) {
          const { data, error } = await supabase.from("prior_year_pl")
            .update(pypUpdates).eq("id", row.pyp_id).select("id");
          if (error) throw error;
          if (!data || data.length === 0) throw new Error("Prior_year_pl update returned no rows (RLS?)");
        }
      }
      cancelEdit();
      await load();
      onDataChanged && onDataChanged();
    } catch (e) {
      console.error("PLDrillPanel save error:", e);
      alert("Save failed: " + (e.message || String(e)));
    } finally {
      setSaving(false);
    }
  };

  const deleteRow = async (row) => {
    const label = row.description || row.account_name || "(no description)";
    if (!confirm(`Delete this transaction?\n\n${label}\nAmount: $${Number(row.amount).toLocaleString()}\nDate: ${row.entry_date}\n\nThis cannot be undone.`)) return;
    setSaving(true);
    try {
      if (row.source === "journal") {
        // Cascade: journal_lines FK is ON DELETE CASCADE, so both sides go.
        const { data, error } = await supabase.from("journal_entries")
          .delete().eq("id", row.je_id).select("id");
        if (error) throw error;
        if (!data || data.length === 0) throw new Error("Journal entry delete returned no rows (RLS?)");
      } else if (row.source === "prior_year_pl") {
        const { data, error } = await supabase.from("prior_year_pl")
          .delete().eq("id", row.pyp_id).select("id");
        if (error) throw error;
        if (!data || data.length === 0) throw new Error("Prior_year_pl delete returned no rows (RLS?)");
      }
      await load();
      onDataChanged && onDataChanged();
    } catch (e) {
      console.error("PLDrillPanel delete error:", e);
      alert("Delete failed: " + (e.message || String(e)));
    } finally {
      setSaving(false);
    }
  };

  const total = rows.reduce((s, r) => s + Number(r.amount || 0), 0);

  return (
    <>
      <div onClick={onClose} style={{ position: "fixed", top: 0, left: 0, right: 0, bottom: 0, background: "rgba(0,0,0,0.35)", zIndex: 999 }} />
      <div role="dialog" aria-label="Transaction drill" style={{
        position: "fixed", top: 0, right: 0, bottom: 0, width: "min(580px, 95vw)",
        background: "#fff", boxShadow: "-4px 0 24px rgba(0,0,0,0.15)", zIndex: 1000,
        display: "flex", flexDirection: "column",
      }}>
        <div style={{ padding: "16px 20px", borderBottom: `1px solid ${T.slate200}`, display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12 }}>
          <div style={{ minWidth: 0, flex: 1 }}>
            <div style={{ fontSize: 10, fontWeight: 600, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.05em" }}>
              {ctx.section} · {ctx.accountType}
            </div>
            <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginTop: 2, wordBreak: "break-word" }}>{ctx.accountName}</div>
            <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>
              {_drillDateFmt(ctx.fromDate)} → {_drillDateFmt(ctx.toDate)}
            </div>
            <div style={{ fontSize: 13, color: T.slate700, marginTop: 6 }}>
              {rows.length} transaction{rows.length !== 1 ? "s" : ""} · <span style={{ fontWeight: 600 }}>{fmt(total)}</span>
            </div>
          </div>
          <button onClick={onClose} aria-label="Close" style={{ background: "none", border: "none", fontSize: 24, cursor: "pointer", color: T.slate500, lineHeight: 1, padding: 4 }}>×</button>
        </div>
        <div style={{ flex: 1, overflowY: "auto" }}>
          {loading && <div style={{ padding: 20, color: T.slate500, fontSize: 13 }}>Loading…</div>}
          {error && <div style={{ padding: 20, color: "#b91c1c", fontSize: 13 }}>Error: {error}</div>}
          {!loading && !error && rows.length === 0 && (
            <div style={{ padding: 20, color: T.slate500, fontSize: 13 }}>No transactions in this range.</div>
          )}
          {!loading && rows.map((row) => {
            const k = rowKey(row);
            const isEditing = editingKey === k;
            const isPrior = row.source === "prior_year_pl";
            return (
              <div key={k} style={{
                padding: "10px 16px",
                borderBottom: `1px solid ${T.slate100}`,
                background: isEditing ? T.slate50 : "transparent",
              }}>
                {!isEditing && (
                  <>
                    <div style={{ display: "flex", justifyContent: "space-between", gap: 8, alignItems: "baseline" }}>
                      <div style={{ fontSize: 11, color: T.slate500 }}>{String(row.entry_date).split("T")[0]}</div>
                      <div style={{ fontSize: 13, fontWeight: 600, color: T.slate900 }}>{fmt(row.amount)}</div>
                    </div>
                    <div style={{ fontSize: 13, color: T.slate800, marginTop: 2, wordBreak: "break-word" }}>
                      {row.description || row.account_name || <span style={{ color: T.slate400, fontStyle: "italic" }}>(no description)</span>}
                    </div>
                    <div style={{ display: "flex", gap: 6, alignItems: "center", marginTop: 4, fontSize: 10, color: T.slate500, flexWrap: "wrap" }}>
                      {row.account_code && <span style={{ padding: "1px 5px", background: T.slate100, borderRadius: 3 }}>{row.account_code}</span>}
                      {isPrior && <span style={{ padding: "1px 5px", background: "#fef3c7", color: "#92400e", borderRadius: 3 }}>prior books</span>}
                      {row.classification_status === "pending_review" && <span style={{ padding: "1px 5px", background: "#fee2e2", color: "#991b1b", borderRadius: 3 }}>suspense</span>}
                      {row.je_source && <span style={{ opacity: 0.65 }}>{row.je_source}</span>}
                      {row.reference_number && <span style={{ opacity: 0.65 }}>ref: {row.reference_number}</span>}
                    </div>
                    <div style={{ marginTop: 8, display: "flex", gap: 6 }}>
                      <button onClick={() => startEdit(row)} disabled={saving} style={_drillBtn}>Edit</button>
                      <button onClick={() => deleteRow(row)} disabled={saving} style={_drillBtnDanger}>Delete</button>
                    </div>
                  </>
                )}
                {isEditing && (
                  <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
                      <div style={{ fontSize: 11, color: T.slate500 }}>Editing txn</div>
                      <div style={{ fontSize: 13, fontWeight: 600, color: T.slate900 }}>
                        {fmt(row.amount)} <span style={{ fontSize: 10, color: T.slate400, fontWeight: 400 }}>(amount not editable)</span>
                      </div>
                    </div>
                    <label style={_drillLabel}>Date
                      <input type="date" value={editDraft.entry_date || ""} onChange={(e) => setEditDraft({ ...editDraft, entry_date: e.target.value })} style={_drillInput} />
                    </label>
                    {!isPrior && (
                      <label style={_drillLabel}>Account
                        <select value={editDraft.account_id || ""} onChange={(e) => setEditDraft({ ...editDraft, account_id: e.target.value })} style={_drillInput}>
                          {coaOptions.map(a => (
                            <option key={a.id} value={a.id}>{a.account_code} · {a.account_name}</option>
                          ))}
                        </select>
                      </label>
                    )}
                    {isPrior && (
                      <label style={_drillLabel}>Account name
                        <input type="text" value={editDraft.account_name || ""} onChange={(e) => setEditDraft({ ...editDraft, account_name: e.target.value })} style={_drillInput} />
                      </label>
                    )}
                    {!isPrior && (
                      <label style={_drillLabel}>Description
                        <input type="text" value={editDraft.description || ""} onChange={(e) => setEditDraft({ ...editDraft, description: e.target.value })} style={_drillInput} />
                      </label>
                    )}
                    <div style={{ display: "flex", gap: 6, marginTop: 4 }}>
                      <button onClick={() => saveEdit(row)} disabled={saving} style={_drillBtnPrimary}>{saving ? "Saving…" : "Save"}</button>
                      <button onClick={cancelEdit} disabled={saving} style={_drillBtn}>Cancel</button>
                    </div>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </>
  );
};

// ─── Section: P&L ────────────────────────────────────────────
// Compact P&L. Grain toggle (monthly / quarterly / annual). Each column
// shows current-period $ paired with a small "same period prior year"
// delta pill. Monthly = Jan..current; Quarterly = last 3 completed
// quarters + QTD (partial) + YTD; Annual = last 3 completed years + YTD.
// Δ colored green (income up / expense down / net up) or red (opposite).
// Prior-value comes from perMonthByYear on each line and represents the
// same period one year prior. Single-row header (parent label spans both the
// $ and Δ cells).
// % of income checkbox adds a per-cell percentage next to each dollar.
// Non-completed periods carry a "(partial)" tag. Partial periods compare
// same-partial slice YoY (e.g. YTD 2026 through Jul vs Jan–Jul 2025).
//
// DRILL: Every leaf account CELL is clickable to open a side panel showing
// every transaction rolling up into that (account × date column) intersection.
// Every leaf account LABEL is clickable to open the same panel scoped to
// the full visible date range for that account. See PLDrillPanel above.
// Section headers, subtotals, Total Income, Total Expenses, and NET INCOME
// are not clickable (per Peter directive 2026-07-17: individual-account grain).
const _somDrill = (y, m) => `${y}-${String(m).padStart(2, "0")}-01`;
const _eomDrill = (y, m) => {
  const d = new Date(Date.UTC(y, m, 0));
  return d.toISOString().split("T")[0];
};

const PLSection = ({ data, onDataChanged, entity, setEntity, breadcrumb, directChildren }) => {
  const pl = data?.pl || { income: [], expenses: [], subsidiaries: [] };
  const incomeRows     = Array.isArray(pl.income)       ? pl.income       : [];
  const expenseRows    = Array.isArray(pl.expenses)     ? pl.expenses     : [];
  // Phase 3 (entity hierarchy): each subsidiary is one synthetic P&L line
  // whose perMonth / perMonthByYear values are the child's ROLLED-UP NET
  // (income − expense) for the period. Rendered as its own section between
  // Total Expenses and NET INCOME. Empty at leaf entities.
  const subsidiaryRows = Array.isArray(pl.subsidiaries) ? pl.subsidiaries : [];

  const year          = data?.currentYear  || new Date().getFullYear();
  const currentMonth  = data?.currentMonth || (new Date().getMonth() + 1);
  const currentQnum   = Math.floor((currentMonth - 1) / 3) + 1;
  const qStartMonth   = (currentQnum - 1) * 3 + 1;
  const priorQnum     = currentQnum === 1 ? 4 : currentQnum - 1;
  const priorQYear    = currentQnum === 1 ? year - 1 : year;
  const priorQStart   = (priorQnum - 1) * 3 + 1;
  const priorQEnd     = priorQStart + 2;

  const [grain, setGrain]     = useState("quarterly"); // monthly | quarterly | annual
  const [showPct, setShowPct] = useState(false);
  const [yearsBack, setYearsBack] = useState("3"); // "3" | "10" | "all"

  // Drill state persisted in URL as pldrill=<accountName>::<section>::<type>::<from>::<to>
  const [drillState, setDrillState] = useTabParam("pldrill", null);
  const drill = (() => {
    if (!drillState) return null;
    const parts = drillState.split("::");
    if (parts.length < 5) return null;
    return { accountName: parts[0], section: parts[1], accountType: parts[2], fromDate: parts[3], toDate: parts[4] };
  })();
  const openDrill = (accountName, section, accountType, fromDate, toDate) => {
    setDrillState(`${accountName}::${section}::${accountType}::${fromDate}::${toDate}`);
  };
  const closeDrill = () => setDrillState(null);

  // --- Column value extractors ------------------------------------------------
  const sum = (arr, from, to) => (Array.isArray(arr) ? arr : []).slice(from, to + 1).reduce((s,x) => s + (x || 0), 0);

  // Each column now also carries fromDate / toDate for drill-down. The
  // dates match the calendar window the getValue() aggregates over.
  const monthCols = () => {
    const cols = [];
    for (let m = 1; m <= currentMonth; m++) {
      cols.push({
        key:      `m${m}`,
        label:    `${MONTHS[m - 1]} ${year}`,
        partial:  (m === currentMonth),
        fromDate: _somDrill(year, m),
        toDate:   _eomDrill(year, m),
        getValue: (line) => line.perMonth[m - 1] || 0,
        getPriorValue: (line) => (line.perMonthByYear?.[year - 1]?.[m - 1] ?? null),
      });
    }
    cols.push({
      key:      "ytd",
      label:    `YTD ${year}`,
      partial:  true,
      fromDate: _somDrill(year, 1),
      toDate:   _eomDrill(year, currentMonth),
      getValue: (line) => sum(line.perMonth, 0, currentMonth - 1),
      getPriorValue: (line) => {
        const arr = line.perMonthByYear?.[year - 1];
        return arr ? sum(arr, 0, currentMonth - 1) : null;
      },
    });
    return cols;
  };

  const sumQ = (arr, qNum) => sum(arr || [], (qNum - 1) * 3, (qNum - 1) * 3 + 2);

  const quarterCols = () => {
    const seq = [];
    let y = year, q = currentQnum;
    for (let i = 0; i < 3; i++) {
      q -= 1;
      if (q === 0) { q = 4; y -= 1; }
      seq.unshift({ year: y, qNum: q });
    }
    const cols = seq.map(({ year: yr, qNum }) => {
      const qs = (qNum - 1) * 3 + 1;
      const qe = qs + 2;
      return {
        key:      `q${yr}-${qNum}`,
        label:    `Q${qNum} ${yr}`,
        partial:  false,
        fromDate: _somDrill(yr, qs),
        toDate:   _eomDrill(yr, qe),
        getValue: (line) => sumQ(line.perMonthByYear?.[yr], qNum),
        getPriorValue: (line) => {
          const arr = line.perMonthByYear?.[yr - 1];
          return arr ? sumQ(arr, qNum) : null;
        },
      };
    });
    cols.push({
      key:      "qtd",
      label:    `Q${currentQnum} ${year} (through ${MONTHS[currentMonth - 1]})`,
      partial:  true,
      fromDate: _somDrill(year, qStartMonth),
      toDate:   _eomDrill(year, currentMonth),
      getValue: (line) => sum(line.perMonth, qStartMonth - 1, currentMonth - 1),
      getPriorValue: (line) => {
        const arr = line.perMonthByYear?.[year - 1];
        return arr ? sum(arr, qStartMonth - 1, currentMonth - 1) : null;
      },
    });
    cols.push({
      key:      "ytd",
      label:    `YTD ${year}`,
      partial:  true,
      fromDate: _somDrill(year, 1),
      toDate:   _eomDrill(year, currentMonth),
      getValue: (line) => sum(line.perMonth, 0, currentMonth - 1),
      getPriorValue: (line) => {
        const arr = line.perMonthByYear?.[year - 1];
        return arr ? sum(arr, 0, currentMonth - 1) : null;
      },
    });
    return cols;
  };

  const annualCols = () => {
    const cols = [];
    let startYear;
    if (yearsBack === "all") {
      const allYears = new Set();
      for (const line of [...incomeRows, ...expenseRows]) {
        if (line.perMonthByYear) {
          for (const yk of Object.keys(line.perMonthByYear)) {
            const n = Number(yk);
            if (Number.isFinite(n) && n < year) allYears.add(n);
          }
        }
      }
      startYear = allYears.size > 0 ? Math.min(...allYears) : year - 3;
    } else {
      startYear = year - Number(yearsBack);
    }
    for (let yr = startYear; yr <= year - 1; yr++) {
      cols.push({
        key:      `y${yr}`,
        label:    `${yr}`,
        partial:  false,
        fromDate: _somDrill(yr, 1),
        toDate:   _eomDrill(yr, 12),
        getValue: (line) => sum(line.perMonthByYear?.[yr], 0, 11),
        getPriorValue: (line) => {
          const arr = line.perMonthByYear?.[yr - 1];
          return arr ? sum(arr, 0, 11) : null;
        },
      });
    }
    cols.push({
      key:      "ytd",
      label:    `YTD ${year} (through ${MONTHS[currentMonth - 1]})`,
      partial:  true,
      fromDate: _somDrill(year, 1),
      toDate:   _eomDrill(year, currentMonth),
      getValue: (line) => sum(line.perMonth, 0, currentMonth - 1),
      getPriorValue: (line) => {
        const arr = line.perMonthByYear?.[year - 1];
        return arr ? sum(arr, 0, currentMonth - 1) : null;
      },
    });
    return cols;
  };

  const columns = grain === "monthly" ? monthCols()
                : grain === "annual"  ? annualCols()
                :                       quarterCols();

  // Full visible date range (used for row-label click drill scope)
  const visibleFrom = columns[0]?.fromDate;
  const visibleTo   = columns[columns.length - 1]?.toDate;

  // --- Totals per column ------------------------------------------------------
  const totalIncomeByCol      = columns.map(c => incomeRows.reduce((s, line) => s + c.getValue(line), 0));
  const totalIncomePriorByCol = columns.map(c => {
    if (!c.getPriorValue) return null;
    let any = false, sum = 0;
    for (const line of incomeRows) {
      const v = c.getPriorValue(line);
      if (v == null) continue;
      any = true; sum += v;
    }
    return any ? sum : null;
  });
  const totalExpByCol      = columns.map(c => expenseRows.reduce((s, line) => s + c.getValue(line), 0));
  const totalExpPriorByCol = columns.map(c => {
    if (!c.getPriorValue) return null;
    let any = false, sum = 0;
    for (const line of expenseRows) {
      const v = c.getPriorValue(line);
      if (v == null) continue;
      any = true; sum += v;
    }
    return any ? sum : null;
  });
  // Phase 3 (entity hierarchy): subsidiary totals feed both the Subsidiaries
  // section footer AND the NET INCOME row (own net + subsidiary net).
  const totalSubByCol      = columns.map(c => subsidiaryRows.reduce((s, line) => s + c.getValue(line), 0));
  const totalSubPriorByCol = columns.map(c => {
    if (!c.getPriorValue) return null;
    let any = false, sum = 0;
    for (const line of subsidiaryRows) {
      const v = c.getPriorValue(line);
      if (v == null) continue;
      any = true; sum += v;
    }
    return any ? sum : null;
  });

  // --- Delta rendering --------------------------------------------------------
  const renderDelta = (cur, prior, opts = {}) => {
    if (prior == null || prior === 0) {
      return <span style={{ color: T.slate400 }}>—</span>;
    }
    const pct = ((cur - prior) / Math.abs(prior)) * 100;
    if (!isFinite(pct)) return <span style={{ color: T.slate400 }}>—</span>;
    const rounded = Math.round(pct);
    const sign = rounded > 0 ? "+" : rounded < 0 ? "−" : "";
    const text = `${sign}${Math.abs(rounded)}%`;
    let color = T.slate500;
    if (rounded !== 0) {
      const { isIncomeLine, isExpenseLine, isNetLine } = opts;
      const goodDirection =
        isExpenseLine ? rounded < 0
      :                 rounded > 0;
      color = goodDirection ? T.green : T.red;
    }
    return <span style={{ color }}>{text}</span>;
  };

  const renderValue = (raw, colIdx) => {
    const dollar = fmt(raw);
    if (!showPct) return dollar;
    const denom = totalIncomeByCol[colIdx] || 0;
    if (!denom) return dollar;
    const pct = (raw / denom) * 100;
    return <>{dollar}<span style={{ color: T.slate400, fontSize: 10, marginLeft: 4 }}>· {pct.toFixed(1)}%</span></>;
  };

  const cellBase = (isTotal, isDelta) => ({
    padding: "7px 8px",
    fontSize: 12,
    textAlign: "right",
    whiteSpace: "nowrap",
    background: isTotal ? T.slate50 : "transparent",
    ...(isDelta ? {
      padding: "7px 4px 7px 2px",
      fontSize: 10,
      width: "1%",
      borderLeft: `1px dotted ${T.slate200}`,
    } : {}),
  });

  // A full data row: label + (value, delta) pairs. If onCellClick /
  // onLabelClick are passed, corresponding surfaces render with a
  // pointer cursor + hover underline. Section headers, subtotals,
  // and Total/Net rows leave these unset and stay non-clickable.
  const DataRow = ({ label, indent, bold, isTotal, values, priors, opts, onCellClick, onLabelClick }) => (
    <tr style={{ background: isTotal ? T.slate50 : "transparent" }}>
      <td
        onClick={onLabelClick}
        style={{
          padding: "7px 8px",
          fontSize: 12,
          color: indent ? T.slate600 : T.slate800,
          paddingLeft: indent ? 24 : 8,
          fontWeight: bold ? 600 : 400,
          whiteSpace: "nowrap",
          cursor: onLabelClick ? "pointer" : "default",
        }}
        title={onLabelClick ? `Show all ${label} transactions in visible range` : undefined}
      >
        {onLabelClick
          ? <span style={{ borderBottom: `1px dotted ${T.slate400}` }}>{label}</span>
          : label}
      </td>
      {columns.flatMap((c, i) => [
        <td
          key={`${c.key}-v`}
          onClick={onCellClick ? () => onCellClick(i) : undefined}
          style={{
            ...cellBase(isTotal, false),
            fontWeight: bold ? 600 : 400,
            color: bold ? T.slate900 : T.slate700,
            cursor: onCellClick ? "pointer" : "default",
          }}
          title={onCellClick ? `Show ${label} transactions for ${c.label}` : undefined}
        >
          {renderValue(values[i], i)}
        </td>,
        <td key={`${c.key}-d`} style={cellBase(isTotal, true)}>
          {renderDelta(values[i], priors[i], opts)}
        </td>,
      ])}
    </tr>
  );

  const lineValues = (line) => columns.map(c => c.getValue(line));
  const linePriors = (line) => columns.map(c => (c.getPriorValue ? c.getPriorValue(line) : null));

  const renderSectionedRows = (lines, opts) => {
    // Peter directive 2026-07-17: any row that is blank across the whole
    // display is not displayed. "Blank" = every visible value column AND
    // every prior-year comparison rounds to $0 (< half a cent). Filtering
    // individual lines before grouping means a section whose surviving
    // children are all blank drops out entirely — header + subtotal row
    // go with them. Total Income / Total Expenses / Net Income are
    // computed outside this function against unfiltered incomeRows /
    // expenseRows, so they still reflect all activity (blank rows
    // contribute $0 so mathematically nothing shifts).
    const isBlankAcrossAllCols = (line) =>
      columns.every(c => {
        const v = c.getValue(line) || 0;
        const p = c.getPriorValue ? (c.getPriorValue(line) || 0) : 0;
        return Math.abs(v) < 0.005 && Math.abs(p) < 0.005;
      });
    const visibleLines = lines.filter(l => !isBlankAcrossAllCols(l));

    const groups = {};
    for (const line of visibleLines) {
      const sec = line.section || "Uncategorized";
      if (!groups[sec]) groups[sec] = [];
      groups[sec].push(line);
    }
    const INCOME_SECTION_RANK = {
      "State Farm":          1,
      "Alliances - SF Comp": 2,
      "IPS - SF Comp":       3,
      "External":            9,
    };
    const rankOf = (sec) => {
      if (opts && opts.isIncomeLine) {
        return INCOME_SECTION_RANK[sec] ?? 5;
      }
      return 0;
    };
    const sectionKeys = Object.keys(groups).sort((a, b) => {
      const ra = rankOf(a), rb = rankOf(b);
      if (ra !== rb) return ra - rb;
      return a.localeCompare(b);
    });
    const accountType = opts?.isIncomeLine ? "income" : "expense";
    const nodes = [];
    sectionKeys.forEach((sec) => {
      const grpLines = groups[sec].slice().sort((a, b) => a.name.localeCompare(b.name));
      const sectionValues = columns.map(c => grpLines.reduce((s, l) => s + c.getValue(l), 0));
      const sectionPriors = columns.map(c => {
        if (!c.getPriorValue) return null;
        let any = false, sum = 0;
        for (const l of grpLines) {
          const v = c.getPriorValue(l);
          if (v !== null && v !== undefined) { any = true; sum += v; }
        }
        return any ? sum : null;
      });
      // Section header — NOT clickable (individual-account grain only)
      nodes.push(
        <DataRow
          key={`sec-${sec}`}
          label={sec}
          bold
          values={sectionValues}
          priors={sectionPriors}
          opts={opts}
        />
      );
      // Leaf accounts — CLICKABLE for drill
      grpLines.forEach((line, i) => {
        nodes.push(
          <DataRow
            key={`${sec}-${i}`}
            label={line.name}
            indent
            values={lineValues(line)}
            priors={linePriors(line)}
            opts={opts}
            onLabelClick={() => openDrill(line.name, sec, accountType, visibleFrom, visibleTo)}
            onCellClick={(colIdx) => {
              const c = columns[colIdx];
              openDrill(line.name, sec, accountType, c.fromDate, c.toDate);
            }}
          />
        );
      });
    });
    return nodes;
  };

  const grainBtn = (key, label) => (
    <button
      key={key}
      onClick={() => setGrain(key)}
      style={{
        padding: "6px 12px",
        fontSize: 12,
        fontWeight: 500,
        background: grain === key ? T.slate800 : "#fff",
        color:      grain === key ? "#fff"     : T.slate600,
        border: `1px solid ${grain === key ? T.slate800 : T.slate200}`,
        borderRadius: 6,
        cursor: "pointer",
      }}
    >{label}</button>
  );

  const totalCellCount = 1 + columns.length * 2;

  return (
    <Card>
      <CardHeader title="Profit & Loss Statement" />

      {/* Entity Hierarchy Nav — breadcrumb + drill-in pills on one line with
          vertical divider. Placed inside the P&L Card between the header and
          the grain buttons per Peter direction 2026-07-19: it belongs to P&L
          specifically since other Financials sections handle entity scoping
          in their own ways. */}
      <EntityNav
        entity={entity}
        setEntity={setEntity}
        breadcrumb={breadcrumb}
        directChildren={directChildren}
      />

      <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "center", padding: "0 0 12px 0" }}>
        {grainBtn("monthly",   "Monthly")}
        {grainBtn("quarterly", "Quarterly")}
        {grainBtn("annual",    "Annual")}
        {grain === "annual" && (
          <label style={{ display: "inline-flex", alignItems: "center", gap: 6, marginLeft: 12, fontSize: 12, color: T.slate600 }}>
            Show:
            <select
              value={yearsBack}
              onChange={(e) => setYearsBack(e.target.value)}
              style={{ padding: "5px 8px", fontSize: 12, background: "#fff", border: `1px solid ${T.slate200}`, borderRadius: 6, color: T.slate800, cursor: "pointer" }}
            >
              <option value="3">Last 3 years + YTD</option>
              <option value="10">Last 10 years + YTD</option>
              <option value="all">All years + YTD</option>
            </select>
          </label>
        )}
        <label style={{ display: "inline-flex", alignItems: "center", gap: 6, marginLeft: 12, fontSize: 12, color: T.slate600, cursor: "pointer" }}>
          <input type="checkbox" checked={showPct} onChange={(e) => setShowPct(e.target.checked)} />
          Show % of income
        </label>
      </div>

      <div style={{ overflowX: "auto" }}>
        <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 640 }}>
          <thead>
            <tr style={{ borderBottom: `2px solid ${T.slate200}` }}>
              <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "left", whiteSpace: "nowrap" }}>Account</th>
              {columns.map((c) => (
                <th key={c.key} colSpan={2} style={{
                  padding: "8px 8px",
                  fontSize: 11,
                  fontWeight: 600,
                  color: T.slate500,
                  textAlign: "center",
                  whiteSpace: "nowrap",
                  borderLeft: `1px solid ${T.slate100}`,
                }}>
                  {c.label}
                  {c.partial && (
                    <div style={{ fontSize: 9, fontWeight: 500, color: T.slate400, marginTop: 2 }}>(partial)</div>
                  )}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            <tr>
              <td style={{ padding: "7px 8px", fontSize: 12, fontWeight: 600, color: T.slate800 }}>INCOME</td>
              <td colSpan={columns.length * 2} />
            </tr>
            {renderSectionedRows(incomeRows, { isIncomeLine: true })}
            <DataRow
              label="Total Income"
              bold isTotal
              values={totalIncomeByCol}
              priors={totalIncomePriorByCol}
              opts={{ isIncomeLine: true }}
            />

            <tr><td colSpan={totalCellCount} style={{ padding: "6px 0" }} /></tr>

            <tr>
              <td style={{ padding: "7px 8px", fontSize: 12, fontWeight: 600, color: T.slate800 }}>EXPENSES</td>
              <td colSpan={columns.length * 2} />
            </tr>
            {renderSectionedRows(expenseRows, { isExpenseLine: true })}
            <DataRow
              label="Total Expenses"
              bold isTotal
              values={totalExpByCol}
              priors={totalExpPriorByCol}
              opts={{ isExpenseLine: true }}
            />

            {/* Phase 3: SUBSIDIARIES — one-line consolidation. Skipped at
                leaf entities (no direct children) and when every subsidiary
                rounds to $0 across every visible column (blank-row filter). */}
            {(() => {
              if (subsidiaryRows.length === 0) return null;
              const visibleSubs = subsidiaryRows.filter(line =>
                columns.some(c => {
                  const v = c.getValue(line) || 0;
                  const p = c.getPriorValue ? (c.getPriorValue(line) || 0) : 0;
                  return Math.abs(v) >= 0.005 || Math.abs(p) >= 0.005;
                })
              );
              if (visibleSubs.length === 0) return null;
              return (
                <>
                  <tr><td colSpan={totalCellCount} style={{ padding: "6px 0" }} /></tr>
                  <tr>
                    <td style={{ padding: "7px 8px", fontSize: 12, fontWeight: 600, color: T.slate800 }}>SUBSIDIARIES</td>
                    <td colSpan={columns.length * 2} />
                  </tr>
                  {visibleSubs.map((sub) => (
                    <DataRow
                      key={`sub-${sub.entityId || sub.name}`}
                      label={sub.name}
                      indent
                      values={lineValues(sub)}
                      priors={linePriors(sub)}
                      opts={{ isIncomeLine: true }}
                    />
                  ))}
                  <DataRow
                    label="Total Subsidiary Net"
                    bold isTotal
                    values={totalSubByCol}
                    priors={totalSubPriorByCol}
                    opts={{ isIncomeLine: true }}
                  />
                </>
              );
            })()}

            <tr><td colSpan={totalCellCount} style={{ padding: "2px 0", borderTop: `2px solid ${T.slate800}` }} /></tr>
            <DataRow
              label="NET INCOME"
              bold isTotal
              values={totalIncomeByCol.map((inc, i) => inc - totalExpByCol[i] + (totalSubByCol[i] || 0))}
              priors={totalIncomePriorByCol.map((incP, i) => {
                const expP = totalExpPriorByCol[i];
                const subP = totalSubPriorByCol[i];
                if (incP == null || expP == null) return null;
                return (incP - expP) + (subP == null ? 0 : subP);
              })}
              opts={{ isNetLine: true }}
            />
          </tbody>
        </table>
      </div>

      {drill && (
        <PLDrillPanel
          ctx={drill}
          onClose={closeDrill}
          onDataChanged={onDataChanged}
        />
      )}
    </Card>
  );
};
// ─── Section: Comp Recap ─────────────────────────────────────
// Grouped by line of business (auto → fire → life → health → ips → bank → pet
// → state_farm_bonuses → expense_reimbursement → reportable_benefit → other →
// deductions), then within each group by new first, then renewal. Each line
// item shows the 1H check, 2H check, and month total side-by-side.
const CompRecapSection = ({ data }) => {
  const compRecaps = Array.isArray(data?.compRecaps) ? data.compRecaps : [];
  const allPeriods = [...new Set(compRecaps.map(r => r?.period_label).filter(Boolean))];
  const [period, setPeriod] = useState("");
  useEffect(() => {
    if (allPeriods.length > 0 && !allPeriods.includes(period)) {
      setPeriod(allPeriods[0]);
    }
  }, [allPeriods.join("|")]);
  const periods  = allPeriods;
  const filtered = compRecaps.filter(r => r.period_label === period);

  // LOB display order + labels
  const LOB_ORDER = [
    { key: "auto",   label: "Auto" },
    { key: "fire",   label: "Fire" },
    { key: "life",   label: "Life" },
    { key: "health", label: "Health" },
    { key: "ips",    label: "IPS" },
    { key: "bank",   label: "Bank" },
    { key: "pet",    label: "Pet" },
  ];
  // Categories that aren't LOB-shaped — collected under separate group headers at the bottom
  const OTHER_GROUPS = [
    { keys: ["state_farm_bonuses"],       label: "State Farm Bonuses" },
    { keys: ["expense_reimbursement"],    label: "Expense Reimbursement" },
    { keys: ["reportable_benefit"],       label: "Reportable Benefits" },
    { keys: ["other"],                    label: "Other" },
  ];

  const humanizeDeduction = (cat) => {
    const map = {
      deduction_advertising:  "Advertising",
      deduction_license:      "Licensing",
      deduction_supplies:     "Supplies",
      deduction_technology:   "Technology",
      deduction_credit_union: "Credit Union",
      deduction_medical:      "Medical",
      deduction_other:        "Other",
    };
    return map[cat] || cat.replace(/^deduction_/, "").replace(/_/g, " ");
  };

  // Sum an array of rows into { h1, h2, total }
  const sumRows = (rows) => rows.reduce((acc, r) => {
    const amt = parseFloat(r.amount || 0);
    if (r.comp_type === "1H") acc.h1 += amt;
    else if (r.comp_type === "2H") acc.h2 += amt;
    acc.total += amt;
    return acc;
  }, { h1: 0, h2: 0, total: 0 });

  // Roll rows into a { description -> { h1, h2, total, is_aipp_eligible } } map
  const rollByDescription = (rows) => {
    const m = new Map();
    for (const r of rows) {
      const key = r.description || `${r.comp_type} — ${r.comp_category}`;
      const cur = m.get(key) || { description: key, h1: 0, h2: 0, total: 0, is_aipp_eligible: r.is_aipp_eligible };
      const amt = parseFloat(r.amount || 0);
      if (r.comp_type === "1H") cur.h1 += amt;
      else if (r.comp_type === "2H") cur.h2 += amt;
      cur.total += amt;
      cur.is_aipp_eligible = cur.is_aipp_eligible || !!r.is_aipp_eligible;
      m.set(key, cur);
    }
    return [...m.values()].sort((a, b) => Math.abs(b.total) - Math.abs(a.total));
  };

  const grandTotal    = filtered.reduce((s, r) => s + parseFloat(r.amount || 0), 0);
  const grandH1       = filtered.filter(r => r.comp_type === "1H").reduce((s, r) => s + parseFloat(r.amount || 0), 0);
  const grandH2       = filtered.filter(r => r.comp_type === "2H").reduce((s, r) => s + parseFloat(r.amount || 0), 0);
  const grandAippTot  = filtered.filter(r => r.is_aipp_eligible).reduce((s, r) => s + parseFloat(r.amount || 0), 0);

  // Cell + subtotal builders
  const money = (n) => fmt(Math.round(n));
  const HeaderRow = ({ label, spans = 5 }) => (
    <tr>
      <td colSpan={spans} style={{ padding: "12px 8px 6px 8px", fontSize: 11, fontWeight: 700, color: T.slate900, background: T.slate50, textTransform: "uppercase", letterSpacing: "0.05em", borderTop: `2px solid ${T.slate200}` }}>{label}</td>
    </tr>
  );
  const SubHeader = ({ label }) => (
    <tr>
      <td colSpan={5} style={{ padding: "6px 8px 4px 20px", fontSize: 10, fontWeight: 600, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.05em" }}>{label}</td>
    </tr>
  );
  const LineRow = ({ r }) => (
    <tr style={{ borderBottom: `1px solid ${T.slate100}` }}>
      <td style={{ padding: "7px 8px 7px 20px", fontSize: 12, color: T.slate800 }}>{r.description}</td>
      <td style={{ padding: "7px 8px", textAlign: "center" }}>
        {r.is_aipp_eligible
          ? <Pill type="success">AIPP</Pill>
          : <span style={{ fontSize: 11, color: T.slate400 }}>—</span>}
      </td>
      <td style={{ padding: "7px 8px", fontSize: 12, color: T.slate700, textAlign: "right" }}>{r.h1 === 0 ? "—" : money(r.h1)}</td>
      <td style={{ padding: "7px 8px", fontSize: 12, color: T.slate700, textAlign: "right" }}>{r.h2 === 0 ? "—" : money(r.h2)}</td>
      <td style={{ padding: "7px 8px", fontSize: 12, fontWeight: 600, color: T.slate900, textAlign: "right" }}>{money(r.total)}</td>
    </tr>
  );
  const SubTotalRow = ({ label, h1, h2, total }) => (
    <tr style={{ borderBottom: `1px solid ${T.slate200}`, background: "#FAFBFC" }}>
      <td style={{ padding: "6px 8px 6px 20px", fontSize: 11, fontWeight: 600, color: T.slate600 }}>{label}</td>
      <td />
      <td style={{ padding: "6px 8px", fontSize: 11, fontWeight: 600, color: T.slate700, textAlign: "right" }}>{money(h1)}</td>
      <td style={{ padding: "6px 8px", fontSize: 11, fontWeight: 600, color: T.slate700, textAlign: "right" }}>{money(h2)}</td>
      <td style={{ padding: "6px 8px", fontSize: 12, fontWeight: 700, color: T.slate900, textAlign: "right" }}>{money(total)}</td>
    </tr>
  );

  // Build rendered body
  const body = [];
  let idx = 0;
  const push = (el) => { body.push(<span key={`k${idx++}`} style={{ display: "contents" }}>{el}</span>); };

  // Main LOBs (auto/fire/life/health/ips/bank/pet)
  for (const lob of LOB_ORDER) {
    const newRows      = filtered.filter(r => r.comp_category === `${lob.key}_new`);
    const renewalRows  = filtered.filter(r => r.comp_category === `${lob.key}_renewal`);
    if (newRows.length === 0 && renewalRows.length === 0) continue;
    const lobRows   = [...newRows, ...renewalRows];
    const lobSum    = sumRows(lobRows);
    const newSum    = sumRows(newRows);
    const renewalSum= sumRows(renewalRows);
    push(<HeaderRow label={lob.label} />);
    if (newRows.length > 0) {
      push(<SubHeader label="New" />);
      for (const r of rollByDescription(newRows)) push(<LineRow r={r} />);
      push(<SubTotalRow label={`${lob.label} New subtotal`} h1={newSum.h1} h2={newSum.h2} total={newSum.total} />);
    }
    if (renewalRows.length > 0) {
      push(<SubHeader label="Renewal" />);
      for (const r of rollByDescription(renewalRows)) push(<LineRow r={r} />);
      push(<SubTotalRow label={`${lob.label} Renewal subtotal`} h1={renewalSum.h1} h2={renewalSum.h2} total={renewalSum.total} />);
    }
    push(<SubTotalRow label={`${lob.label} total`} h1={lobSum.h1} h2={lobSum.h2} total={lobSum.total} />);
  }

  // Non-LOB groups (bonuses, reimbursement, benefits, other)
  for (const grp of OTHER_GROUPS) {
    const rows = filtered.filter(r => grp.keys.includes(r.comp_category));
    if (rows.length === 0) continue;
    const grpSum = sumRows(rows);
    push(<HeaderRow label={grp.label} />);
    for (const r of rollByDescription(rows)) push(<LineRow r={r} />);
    push(<SubTotalRow label={`${grp.label} total`} h1={grpSum.h1} h2={grpSum.h2} total={grpSum.total} />);
  }

  // Deductions group — last, one row per deduction sub-category
  const deductionRows = filtered.filter(r => (r.comp_category || "").startsWith("deduction_"));
  if (deductionRows.length > 0) {
    const dedSum = sumRows(deductionRows);
    push(<HeaderRow label="Deductions" />);
    // Group by deduction sub-category
    const subCats = [...new Set(deductionRows.map(r => r.comp_category))];
    for (const cat of subCats) {
      const catRows = deductionRows.filter(r => r.comp_category === cat);
      const catSum  = sumRows(catRows);
      push(<SubHeader label={humanizeDeduction(cat)} />);
      for (const r of rollByDescription(catRows)) push(<LineRow r={r} />);
      push(<SubTotalRow label={`${humanizeDeduction(cat)} subtotal`} h1={catSum.h1} h2={catSum.h2} total={catSum.total} />);
    }
    push(<SubTotalRow label="Deductions total" h1={dedSum.h1} h2={dedSum.h2} total={dedSum.total} />);
  }

  return (
    <Card>
      <CardHeader
        title="SF Comp Recap Detail"
        sub="State Farm compensation, grouped by line of business · new then renewal · 1H = first-half check, 2H = second-half check"
      />
      <div style={{ display: "flex", gap: 8, marginBottom: 14, flexWrap: "wrap" }}>
        {periods.map(p => (
          <button key={p} onClick={() => setPeriod(p)} style={{
            padding: "5px 12px", fontSize: 11, fontWeight: period===p ? 600 : 400,
            color: period===p ? T.white : T.slate600,
            background: period===p ? T.slate900 : T.white,
            border: `1px solid ${period===p ? T.slate900 : T.slate200}`,
            borderRadius: 6, cursor: "pointer",
          }}>{p}</button>
        ))}
      </div>

      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
      <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 640 }}>
        <thead>
          <tr style={{ borderBottom: `1px solid ${T.slate200}` }}>
            <th style={{ padding: "8px 8px 8px 20px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "left" }}>Line Item</th>
            <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "center" }}>AIPP</th>
            <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "right" }}>Check 1 (1H)</th>
            <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "right" }}>Check 2 (2H)</th>
            <th style={{ padding: "8px 8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: "right" }}>Month Total</th>
          </tr>
        </thead>
        <tbody>
          {body}
        </tbody>
        <tfoot>
          <tr style={{ borderTop: `2px solid ${T.slate800}` }}>
            <td style={{ padding: "10px 8px 10px 20px", fontSize: 12, fontWeight: 700, color: T.slate900 }}>Grand total</td>
            <td style={{ padding: "10px 8px", fontSize: 11, textAlign: "center", color: T.slate500 }}>AIPP: {fmt(grandAippTot)}</td>
            <td style={{ padding: "10px 8px", fontSize: 12, fontWeight: 700, color: T.slate900, textAlign: "right" }}>{money(grandH1)}</td>
            <td style={{ padding: "10px 8px", fontSize: 12, fontWeight: 700, color: T.slate900, textAlign: "right" }}>{money(grandH2)}</td>
            <td style={{ padding: "10px 8px", fontSize: 13, fontWeight: 700, color: T.blue, textAlign: "right" }}>{money(grandTotal)}</td>
          </tr>
        </tfoot>
      </table>
      </div>
    </Card>
  );
};

// ─── Section: Payroll ─────────────────────────────────────────
// Enumerates every Sunday–Saturday week from the earliest recorded run through
// the current week. Recorded runs render normally; expected-but-missing weeks
// render as blank rows tagged "Missing" so gaps are visually obvious.
const PayrollSection = ({ data }) => {
  const rows = Array.isArray(data.payroll) ? data.payroll : [];
  const ytdGross = rows.reduce((s,r) => s + parseFloat(r.gross || 0), 0);
  const ytdTax   = rows.reduce((s,r) => s + parseFloat(r.taxes || 0), 0);

  // Parse "MMM d – MMM d, yyyy" pay_period back to a Date for the period start (Sunday).
  // Payroll data hook doesn't preserve the raw start date, so we reconstruct from the label.
  const parsePeriodStart = (r) => {
    const label = r.pay_period || r.period || "";
    const parts = label.split(" – ");
    if (parts.length !== 2) return null;
    // parts[1] carries the year: "Jul 4, 2026" — use its year with parts[0]'s "Jun 28".
    const yearMatch = parts[1].match(/(\d{4})/);
    if (!yearMatch) return null;
    const year = yearMatch[1];
    const d = new Date(`${parts[0]} ${year}`);
    return Number.isFinite(d.getTime()) ? d : null;
  };
  // Sunday-anchored week key (yyyy-mm-dd)
  const toSundayKey = (d) => {
    const dt = new Date(d);
    dt.setHours(0,0,0,0);
    // Pay period always starts on a Sunday; if the parsed date drifted, snap back.
    if (dt.getDay() !== 0) dt.setDate(dt.getDate() - dt.getDay());
    return dt.toISOString().split("T")[0];
  };

  // Build a map of recorded rows by Sunday key
  const byKey = new Map();
  let earliest = null, latest = null;
  for (const r of rows) {
    const start = parsePeriodStart(r);
    if (!start) continue;
    const key = toSundayKey(start);
    byKey.set(key, { ...r, _start: start });
    if (!earliest || start < earliest) earliest = start;
    if (!latest   || start > latest)   latest = start;
  }

  // Enumerate weeks between earliest and current-week-start
  let enumerated = [];
  if (earliest) {
    const now = new Date();
    const curStart = new Date(now);
    curStart.setHours(0,0,0,0);
    curStart.setDate(curStart.getDate() - curStart.getDay()); // this week's Sunday
    const stopAt = latest && latest > curStart ? latest : curStart;
    const cursor = new Date(earliest);
    while (cursor <= stopAt) {
      const key = toSundayKey(cursor);
      if (byKey.has(key)) {
        enumerated.push({ kind: "row", key, row: byKey.get(key) });
      } else {
        const end = new Date(cursor); end.setDate(end.getDate() + 6);
        const payDate = new Date(end); payDate.setDate(payDate.getDate() + 6); // Fri after Saturday period end
        const fmtDate = (d, opts) => d.toLocaleDateString("en-US", opts);
        enumerated.push({
          kind: "blank", key,
          label: `${fmtDate(cursor, {month:"short", day:"numeric"})} – ${fmtDate(end, {month:"short", day:"numeric", year:"numeric"})}`,
          payDate: fmtDate(payDate, {month:"short", day:"numeric", year:"numeric"}),
        });
      }
      cursor.setDate(cursor.getDate() + 7);
    }
    // Show most recent first
    enumerated.sort((a,b) => (a.key < b.key ? 1 : -1));
  } else {
    // No data — nothing to enumerate; falls through to empty tbody
    enumerated = [];
  }

  const missingCount = enumerated.filter(e => e.kind === "blank").length;

  return (
    <Card>
      <CardHeader
        title="Payroll History"
        sub={`YTD Gross: ${fmt(ytdGross)} · YTD Taxes: ${fmt(ytdTax)}${missingCount ? ` · ${missingCount} missing week${missingCount === 1 ? "" : "s"}` : ""}`}
      />
      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead>
          <tr style={{ borderBottom: `1px solid ${T.slate200}` }}>
            {["Pay Period","Pay Date","Gross","Employer Taxes","Net Payroll","Status"].map((h,i) => (
              <th key={i} style={{ padding: "8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: i > 1 ? "right" : "left" }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {enumerated.map((e,i) => {
            if (e.kind === "row") {
              const r = e.row;
              return (
                <tr key={e.key} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                  <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate800 }}>{r.pay_period||r.period}</td>
                  <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate600 }}>{r.pay_date||r.payDate||"-"}</td>
                  <td style={{ padding: "9px 8px", fontSize: 12, fontWeight: 600, color: T.slate900, textAlign: "right" }}>{fmt(r.gross)}</td>
                  <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate700, textAlign: "right" }}>{fmt(parseFloat(r.taxes||0))}</td>
                  <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate700, textAlign: "right" }}>{fmt(parseFloat(r.net||0))}</td>
                  <td style={{ padding: "9px 8px", textAlign: "right" }}>
                    <Pill type="success">{r.status}</Pill>
                  </td>
                </tr>
              );
            }
            // Missing week
            return (
              <tr key={e.key} style={{ borderBottom: `1px solid ${T.slate100}`, background: T.amberLt + "40" }}>
                <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate500, fontStyle: "italic" }}>{e.label}</td>
                <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate400 }}>{e.payDate}</td>
                <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate400, textAlign: "right" }}>—</td>
                <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate400, textAlign: "right" }}>—</td>
                <td style={{ padding: "9px 8px", fontSize: 12, color: T.slate400, textAlign: "right" }}>—</td>
                <td style={{ padding: "9px 8px", textAlign: "right" }}>
                  <Pill type="warning">Missing</Pill>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      </div>
    </Card>
  );
};

// ─── Section: Bank Accounts ───────────────────────────────────
const BankSection = ({ data }) => {
  const allBankAccounts = Array.isArray(data?.bankAccounts) ? data.bankAccounts : [];
  // Phase 4: filter to accounts stamped anywhere in the current entity's
  // subtree (Option B — flat listing across whole subtree with per-account
  // badge). At Personal (root), every account shows regardless of which
  // subsidiary owns it. At a leaf, only accounts stamped directly on that
  // leaf show. entitiesById + descendants both derive client-side from the
  // 5-entity map already fetched by the hook — no extra roundtrip.
  const ctx = data?.entityContext || {};
  const allEntities = Array.isArray(ctx.allEntities) ? ctx.allEntities : [];
  const entitiesById = Object.fromEntries(allEntities.map(e => [e.id, e]));
  const allow = descendantsOf(ctx.currentEntityId, allEntities);
  const bankAccounts = allEntities.length === 0
    ? allBankAccounts                                                              // fallback: pre-Phase 3 shape
    : allBankAccounts.filter(a => !a.businessEntityId || allow.has(a.businessEntityId));
  const totalCash = bankAccounts.reduce((s,r) => s + (r?.balance || 0), 0);
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px,1fr))", gap: 10 }}>
        {bankAccounts.map((a, i) => {
          const entName = a.businessEntityId ? entitiesById[a.businessEntityId]?.name : null;
          return (
            <Card key={i}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 8 }}>
                <div style={{ fontSize: 11, fontWeight: 600, color: T.slate700 }}>{a.name}</div>
                {a.needsStatement ? (
                  <Pill type="warning">Awaiting stmt</Pill>
                ) : a.needsReview ? (
                  <Pill type="warning">Review</Pill>
                ) : null}
              </div>
              <div style={{ fontSize: 10, color: T.slate500, marginBottom: 6, letterSpacing: "0.02em" }}>
                {[a.institution, a.last4 ? `••${a.last4}` : null].filter(Boolean).join(" · ") || <span style={{ color: T.amber }}>Add institution / last 4</span>}
              </div>
              {entName && (
                <div style={{ marginBottom: 6 }}>
                  <span style={{
                    display: "inline-block",
                    padding: "2px 7px",
                    fontSize: 9,
                    fontWeight: 600,
                    color: T.slate700,
                    background: T.slate100,
                    border: `1px solid ${T.slate200}`,
                    borderRadius: 999,
                    letterSpacing: "0.02em",
                  }}>{entName}</span>
                </div>
              )}
              <div style={{ fontSize: 24, fontWeight: 700, color: T.slate900, letterSpacing: "-0.02em" }}>
                {fmt(a.balance)}
              </div>
              <div style={{ fontSize: 10, color: T.slate400, marginTop: 4 }}>
                {a.needsStatement ? "No balance yet — statement pending" : a.asOf ? `As of ${a.asOf}` : "Ledger-derived balance"}
              </div>
            </Card>
          );
        })}
        <Card style={{ background: T.slate900, border: "none" }}>
          <div style={{ fontSize: 11, fontWeight: 600, color: "rgba(255,255,255,0.7)", marginBottom: 8 }}>Total Cash Position</div>
          <div style={{ fontSize: 26, fontWeight: 700, color: T.white, letterSpacing: "-0.02em" }}>{fmt(totalCash)}</div>
          <div style={{ fontSize: 10, color: "rgba(255,255,255,0.5)", marginTop: 4 }}>
            {bankAccounts.length === allBankAccounts.length ? "All accounts combined" : `${bankAccounts.length} of ${allBankAccounts.length} accounts (subtree)`}
          </div>
        </Card>
      </div>
    </div>
  );
};

// ─── Section: Credit & Debt ───────────────────────────────────
// One line per account: on desktop everything fits horizontally, on phones it
// wraps naturally onto multiple lines via flex-wrap + minmax fields.
const CreditSection = ({ data }) => {
  const allAccounts = Array.isArray(data.creditAccounts) ? data.creditAccounts : [];
  // Phase 4: filter to current subtree (Option B — flat listing with per-row
  // entity badge). Same pattern as BankSection above.
  const ctx = data?.entityContext || {};
  const allEntities = Array.isArray(ctx.allEntities) ? ctx.allEntities : [];
  const entitiesById = Object.fromEntries(allEntities.map(e => [e.id, e]));
  const allow = descendantsOf(ctx.currentEntityId, allEntities);
  const accounts = allEntities.length === 0
    ? allAccounts
    : allAccounts.filter(a => !a.businessEntityId || allow.has(a.businessEntityId));
  const totalDebt      = accounts.reduce((s,r) => s + (r?.balance || 0), 0);
  const totalAvailable = accounts.filter(a => a.limit).reduce((s,r) => s + (r.limit - r.balance), 0);

  const typeLabel = (t) => t === "credit_card" ? "Credit Card" : t === "loan" ? "Loan" : "Line of Credit";

  // Compact one-line row (flex-wrap fires only when the row runs out of horizontal room, i.e. phones)
  const AccountRow = ({ a }) => {
    const util = a.limit ? pct(a.balance, a.limit) : null;
    const utilColor = util == null ? T.slate400 : util > 30 ? T.amber : T.green;
    const entName = a.businessEntityId ? entitiesById[a.businessEntityId]?.name : null;
    const Field = ({ label, value, color = T.slate900, minWidth = 90 }) => (
      <div style={{ minWidth, flex: "0 1 auto" }}>
        <div style={{ fontSize: 9, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.04em" }}>{label}</div>
        <div style={{ fontSize: 13, fontWeight: 700, color }}>{value}</div>
      </div>
    );
    return (
      <div style={{
        display: "flex", flexWrap: "wrap", alignItems: "center", gap: "10px 18px",
        padding: "10px 14px",
        background: T.white,
        border: `1px solid ${T.slate200}`,
        borderRadius: 10,
      }}>
        <div style={{ flex: "1 1 220px", minWidth: 180 }}>
          <div style={{ fontSize: 13, fontWeight: 600, color: T.slate800, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
            <span>{a.name}</span>
            {entName && (
              <span style={{
                display: "inline-block",
                padding: "1px 7px",
                fontSize: 9,
                fontWeight: 600,
                color: T.slate700,
                background: T.slate100,
                border: `1px solid ${T.slate200}`,
                borderRadius: 999,
                letterSpacing: "0.02em",
              }}>{entName}</span>
            )}
          </div>
          <div style={{ fontSize: 10, color: T.slate500, marginTop: 1 }}>
            {[a.institution, a.last4 ? `••${a.last4}` : null].filter(Boolean).join(" · ")}
            {(a.institution || a.last4) ? " · " : ""}
            {typeLabel(a.type)}{a.rate ? ` · ${a.rate}% APR` : ""}
            {a.needsLast4 ? <span style={{ color: T.amber, marginLeft: 6 }}>· Add last 4</span> : null}
            {a.needsReview ? <span style={{ display: "inline-flex", verticalAlign: "middle", marginLeft: 6 }}><Pill type="warning">Review</Pill></span> : null}
          </div>
        </div>
        <Field label="Balance"   value={fmt(a.balance)} color={T.red} />
        {a.limit ? <Field label="Available" value={fmt(a.limit - a.balance)} color={T.green} /> : null}
        {a.payment ? <Field label="Min Pmt" value={fmt(a.payment)} color={T.amber} /> : null}
        {a.dueDay ? <Field label="Due" value={`Day ${a.dueDay}`} color={T.slate700} minWidth={60} /> : null}
        {a.limit ? (
          <div style={{ minWidth: 110, flex: "0 1 auto" }}>
            <div style={{ display: "flex", justifyContent: "space-between", fontSize: 9, color: T.slate500, marginBottom: 2, letterSpacing: "0.04em", textTransform: "uppercase" }}>
              <span>Utilization</span><span style={{ color: utilColor, fontWeight: 700 }}>{util}%</span>
            </div>
            <ProgressBar value={a.balance} max={a.limit} color={utilColor} height={5} />
          </div>
        ) : null}
      </div>
    );
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px,1fr))", gap: 10, marginBottom: 4 }}>
        <KPICard label="Total Debt Exposure" value={fmt(totalDebt)} color={T.red} border={T.red} />
        <KPICard label="Available Credit" value={fmt(totalAvailable)} color={T.green} border={T.green} />
        <KPICard label="Accounts Tracked" value={String(accounts.length)} sub={accounts.length === allAccounts.length ? "Balances from ledger" : `of ${allAccounts.length} agency-wide`} border={T.amber} />
      </div>
      {accounts.map((a, i) => <AccountRow key={i} a={a} />)}
    </div>
  );
};

// ─── Section: Balance Sheet ───────────────────────────────────
const BalanceSheetSection = ({ data }) => {
  const bs = data?.balanceSheet || { assets: [], liabilities: [], equity: [], totalAssets: 0, totalLiabilities: 0, totalEquity: 0, asOfLabel: "" };

  // Phase 5: filter rows to current entity's subtree (Option B — flat listing
  // across whole subtree with per-row entity badge, same pattern as
  // BankSection / CreditSection from Phase 4). Totals recompute from filtered
  // rows so subtree-view totals reflect what's shown, and the ties check works
  // against the actual displayed slice. entitiesById + descendants derive
  // client-side from the 5-entity map already fetched by the hook.
  const ctx = data?.entityContext || {};
  const allEntities = Array.isArray(ctx.allEntities) ? ctx.allEntities : [];
  const entitiesById = Object.fromEntries(allEntities.map(e => [e.id, e]));
  const allow = descendantsOf(ctx.currentEntityId, allEntities);
  const inScope = (r) => allEntities.length === 0 || !r.businessEntityId || allow.has(r.businessEntityId);

  const allAssets = Array.isArray(bs.assets) ? bs.assets : [];
  const allLiabilities = Array.isArray(bs.liabilities) ? bs.liabilities : [];
  const allEquity = Array.isArray(bs.equity) ? bs.equity : [];
  const assets = allAssets.filter(inScope);
  const liabilities = allLiabilities.filter(inScope);
  const equity = allEquity.filter(inScope);

  const totalAssets = assets.reduce((s,r) => s + (r?.balance || 0), 0);
  const totalLiabilities = liabilities.reduce((s,r) => s + (r?.balance || 0), 0);
  const totalEquity = equity.reduce((s,r) => s + (r?.balance || 0), 0);
  const totalLE = totalLiabilities + totalEquity;
  const ties = Math.abs(totalAssets - totalLE) < 1;

  const totalShown = assets.length + liabilities.length + equity.length;
  const totalAll = allAssets.length + allLiabilities.length + allEquity.length;
  const subtreeLabel = allEntities.length > 0 && totalShown !== totalAll
    ? ` · ${totalShown} of ${totalAll} accounts (subtree)`
    : "";

  const EntityPill = ({ id }) => {
    if (!id) return null;
    const name = entitiesById[id]?.name;
    if (!name) return null;
    return (
      <span style={{
        display: "inline-block",
        marginLeft: 8,
        padding: "1px 6px",
        fontSize: 9,
        fontWeight: 600,
        color: T.slate700,
        background: T.slate100,
        border: `1px solid ${T.slate200}`,
        borderRadius: 999,
        letterSpacing: "0.02em",
        verticalAlign: "middle",
      }}>{name}</span>
    );
  };

  const Row = ({ name, amount, bold, indent, entityId }) => (
    <tr style={{ background: bold ? T.slate50 : "transparent" }}>
      <td style={{ padding: "7px 8px", fontSize: 12, color: indent ? T.slate600 : T.slate800, paddingLeft: indent ? 24 : 8, fontWeight: bold ? 700 : 400 }}>
        {name}
        {!bold && entityId && <EntityPill id={entityId} />}
      </td>
      <td style={{ padding: "7px 8px", fontSize: 12, textAlign: "right", fontWeight: bold ? 700 : 400, color: amount < 0 ? T.red : bold ? T.slate900 : T.slate700 }}>{fmt(Math.round(amount))}</td>
    </tr>
  );

  return (
    <Card>
      <CardHeader
        title="Balance Sheet"
        sub={`Anchored to 6/30/2026 close + live GL · As of ${bs.asOfLabel || "current"}${subtreeLabel}`}
      />

      {!ties && (
        <div style={{ marginBottom: 12, padding: "8px 12px", background: T.amberLt, borderRadius: 8, fontSize: 11, color: "#92400E", borderLeft: `3px solid ${T.amber}` }}>
          Note: Assets do not currently equal Liabilities + Equity. This indicates GL activity awaiting reconciliation.
        </div>
      )}

      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <tbody>
          <Row name="ASSETS" bold />
          {assets.map((r,i) => <Row key={`a${i}`} name={r.name} amount={r.balance} indent entityId={r.businessEntityId} />)}
          <Row name="Total Assets" amount={totalAssets} bold />

          <tr><td colSpan={2} style={{ padding: "6px 0" }} /></tr>

          <Row name="LIABILITIES" bold />
          {liabilities.map((r,i) => <Row key={`l${i}`} name={r.name} amount={r.balance} indent entityId={r.businessEntityId} />)}
          <Row name="Total Liabilities" amount={totalLiabilities} bold />

          <tr><td colSpan={2} style={{ padding: "6px 0" }} /></tr>

          <Row name="EQUITY" bold />
          {equity.map((r,i) => <Row key={`e${i}`} name={r.name} amount={r.balance} indent entityId={r.businessEntityId} />)}
          <Row name="Total Equity" amount={totalEquity} bold />

          <tr><td colSpan={2} style={{ padding: "2px 0", borderTop: `2px solid ${T.slate800}` }} /></tr>
          <Row name="Total Liabilities + Equity" amount={totalLE} bold />
        </tbody>
      </table>
      </div>
    </Card>
  );
};

// ─── Section: General Ledger ──────────────────────────────────
const GLSection = ({ data }) => {
  // Phase 6 (entity hierarchy): filter to current entity's subtree — Option B
  // flat listing across whole subtree with per-row entity badge, same pattern
  // as Bank / Credit / BalanceSheet sections from Phases 4-5. entitiesById +
  // descendants derive client-side from the 5-entity map already fetched by
  // the hook. Fetch pulls 200 most-recent lines to give the subtree filter
  // headroom; display slices to 50 after filtering so mobile stays tight.
  const allEntries = Array.isArray(data?.glEntries) ? data.glEntries : [];
  const ctx = data?.entityContext || {};
  const allEntities = Array.isArray(ctx.allEntities) ? ctx.allEntities : [];
  const entitiesById = Object.fromEntries(allEntities.map(e => [e.id, e]));
  const allow = descendantsOf(ctx.currentEntityId, allEntities);
  const filtered = allEntities.length === 0
    ? allEntries
    : allEntries.filter(r => !r.businessEntityId || allow.has(r.businessEntityId));
  const entries = filtered.slice(0, 50);

  const subtreeLabel = allEntities.length > 0 && filtered.length !== allEntries.length
    ? ` · ${entries.length} of ${filtered.length} matched (subtree)`
    : ` · ${entries.length} most recent`;

  return (
    <Card>
      <CardHeader
        title="General Ledger — Recent Entries"
        sub={`All accounts${subtreeLabel}`}
      />
      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead>
          <tr style={{ borderBottom: `1px solid ${T.slate200}` }}>
            {["Date","Ref","Description","Account","Entity","Debit","Credit"].map((h,i) => (
              <th key={i} style={{ padding: "8px", fontSize: 11, fontWeight: 600, color: T.slate500, textAlign: i >= 5 ? "right" : "left" }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {entries.map((r,i) => {
            const entName = r.businessEntityId ? entitiesById[r.businessEntityId]?.name : null;
            return (
              <tr key={i} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                <td style={{ padding: "8px", fontSize: 11, color: T.slate500 }}>{r.date}</td>
                <td style={{ padding: "8px", fontSize: 11, color: T.blue, fontFamily: "monospace" }}>{r.ref}</td>
                <td style={{ padding: "8px", fontSize: 12, color: T.slate800 }}>{r.description}</td>
                <td style={{ padding: "8px", fontSize: 11, color: T.slate500, fontFamily: "monospace" }}>{r.account}</td>
                <td style={{ padding: "8px", fontSize: 11 }}>
                  {entName ? (
                    <span style={{
                      display: "inline-block",
                      padding: "1px 6px",
                      fontSize: 9,
                      fontWeight: 600,
                      color: T.slate700,
                      background: T.slate100,
                      border: `1px solid ${T.slate200}`,
                      borderRadius: 999,
                      letterSpacing: "0.02em",
                    }}>{entName}</span>
                  ) : <span style={{ color: T.slate400 }}>—</span>}
                </td>
                <td style={{ padding: "8px", fontSize: 12, textAlign: "right", color: T.slate900, fontWeight: r.debit ? 500 : 400 }}>{r.debit ? fmt(r.debit) : "—"}</td>
                <td style={{ padding: "8px", fontSize: 12, textAlign: "right", color: T.green, fontWeight: r.credit ? 500 : 400 }}>{r.credit ? fmt(r.credit) : "—"}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
      </div>
    </Card>
  );
};

// ─── CPA-Style Print Package ──────────────────────────────────
// Browser-native print: hidden on screen, shown only when printing.
const PRINT_CSS = `
@media screen { .newtworks-print-package { display: none !important; } }
@media print {
  body * { visibility: hidden !important; }
  .newtworks-print-package, .newtworks-print-package * { visibility: visible !important; }
  .newtworks-print-package { position: absolute; left: 0; top: 0; width: 100%; display: block !important; padding: 0; }
  .newtworks-print-page { page-break-after: always; padding: 32px 36px; }
  .newtworks-print-page:last-child { page-break-after: auto; }
  .newtworks-no-print { display: none !important; }
  @page { size: letter portrait; margin: 0.5in; }
}
`;

const PrintTable = ({ title, sub, rows, cols }) => (
  <div style={{ marginBottom: 22 }}>
    <div style={{ fontSize: 15, fontWeight: 700, color: "#0F172A", marginBottom: 2 }}>{title}</div>
    {sub && <div style={{ fontSize: 11, color: "#64748B", marginBottom: 8 }}>{sub}</div>}
    <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
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
    <div className="newtworks-print-package">
      <style>{PRINT_CSS}</style>

      {/* Cover Page */}
      <div className="newtworks-print-page" style={{ textAlign: "center", paddingTop: 180 }}>
        <div style={{ fontSize: 28, fontWeight: 700, color: "#1B2B4B", marginBottom: 8 }}>Paper Newt Management LLC</div>
        <div style={{ fontSize: 18, color: "#334155", marginBottom: 40 }}>Financial Statements Package</div>
        <div style={{ fontSize: 15, color: "#475569", marginBottom: 4 }}>Period: {periodName}</div>
        <div style={{ fontSize: 12, color: "#64748B", marginBottom: 60 }}>Cash basis · Calendar year · All figures in USD</div>
        <div style={{ fontSize: 11, color: "#94A3B8" }}>Prepared {today}</div>
        <div style={{ fontSize: 11, color: "#94A3B8", marginTop: 4 }}>Newtworks</div>
        <div style={{ marginTop: 80, fontSize: 10, color: "#94A3B8", maxWidth: 420, marginLeft: "auto", marginRight: "auto", lineHeight: 1.5 }}>
          This package contains the Profit &amp; Loss Statement, Balance Sheet, Bank Account balances,
          and Credit &amp; Debt balances. Balance Sheet is anchored to the 6/30/2026 statement close
          plus subsequent general-ledger activity.
        </div>
      </div>

      {/* P&L Page */}
      <div className="newtworks-print-page">
        <PrintTable
          title="Profit & Loss Statement"
          sub={`Cash basis · ${d.currentYear || ""}`}
          cols={["Account", periodName, `Q${qN} ${d.currentYear||""}`, `YTD ${d.currentYear||""}`]}
          rows={plRows}
        />
      </div>

      {/* Balance Sheet Page */}
      <div className="newtworks-print-page">
        <PrintTable
          title="Balance Sheet"
          sub={`As of ${bs.asOfLabel || periodName} · anchored to 6/30/2026 close + GL activity`}
          cols={["Account", "Balance"]}
          rows={bsRows}
        />
      </div>

      {/* Bank + Credit Page */}
      <div className="newtworks-print-page">
        <PrintTable title="Bank Accounts" sub="Ledger-derived balances" cols={["Account","Balance"]} rows={bankRows} />
        <PrintTable title="Credit & Debt" sub="Outstanding balances" cols={["Account","Balance"]} rows={creditRows} />
      </div>
    </div>
  );
};

// ─── Entity Hierarchy Nav (Phase 3) ───────────────────────────
// Breadcrumb (root → current, each segment right-clickable) + a horizontal
// strip of direct children as clickable pills that drill INTO a child. Both
// render as real <a href> anchors so browsers expose native "Open in new
// tab" affordances per operational_rule "Newtworks nav-target UI elements
// must be <a href>".
const EntityNav = ({ entity, setEntity, breadcrumb, directChildren }) => {
  const crumbs = Array.isArray(breadcrumb)     ? breadcrumb     : [];
  const kids   = Array.isArray(directChildren) ? directChildren : [];
  if (crumbs.length === 0 && kids.length === 0) return null;

  const goTo = (id) => setEntity(id || PERSONAL_ROOT_ENTITY_ID);
  const showDivider = crumbs.length > 0 && kids.length > 0;

  return (
    <div style={{
      background: T.slate50,
      border: `1px solid ${T.slate200}`,
      borderRadius: 10,
      padding: "10px 14px",
      marginBottom: 14,
      display: "flex",
      flexWrap: "wrap",
      alignItems: "center",
      gap: 8,
      fontSize: 13,
    }}>
      {/* Breadcrumb — root first, current last (non-clickable) */}
      {crumbs.map((c, i) => {
        const isCurrent = i === crumbs.length - 1;
        const sep = i > 0 ? (
          <span key={`sep-${c.id}`} style={{ color: T.slate400, margin: "0 4px" }}>›</span>
        ) : null;
        if (isCurrent) {
          return (
            <span key={c.id} style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
              {sep}
              <span style={{ fontWeight: 600, color: T.slate900 }}>{c.name}</span>
            </span>
          );
        }
        return (
          <span key={c.id} style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
            {sep}
            <a
              href={urlWithEntity(c.id)}
              onClick={(e) => handleModuleLinkClick(e, () => goTo(c.id))}
              style={{
                color: T.blue,
                textDecoration: "none",
                borderBottom: `1px dotted ${T.blue}`,
              }}
              title={`Switch Financials scope to ${c.name}`}
            >{c.name}</a>
          </span>
        );
      })}

      {/* Vertical divider — only when both breadcrumb and drill-in are present */}
      {showDivider && (
        <div style={{
          width: 1,
          alignSelf: "stretch",
          background: T.slate300,
          margin: "0 4px",
        }} />
      )}

      {/* Drill-in pills — each drills INTO a child entity */}
      {kids.length > 0 && (
        <>
          <span style={{ fontSize: 11, color: T.slate500, marginRight: 2 }}>Drill in →</span>
          {kids.map(k => (
            <a
              key={k.id}
              href={urlWithEntity(k.id)}
              onClick={(e) => handleModuleLinkClick(e, () => goTo(k.id))}
              style={{
                display: "inline-flex",
                alignItems: "center",
                gap: 6,
                padding: "5px 10px",
                fontSize: 12,
                fontWeight: 500,
                color: T.slate800,
                background: T.white,
                border: `1px solid ${T.slate200}`,
                borderRadius: 999,
                textDecoration: "none",
                cursor: "pointer",
              }}
              title={`Drill into ${k.name}`}
            >
              <span>{k.name}</span>
              <span style={{ fontSize: 10, color: T.slate400 }}>{k.entity_type}</span>
              {!k.is_leaf && <span style={{ fontSize: 10, color: T.slate400 }}>· {k.direct_child_count} sub</span>}
            </a>
          ))}
        </>
      )}
    </div>
  );
};

// ─── Main Financials Module ───────────────────────────────────
export default function Financials() {
  const [section, setSection] = useTabParam("tab", "overview", ["overview","pl","balsheet","comp","credit","bank","gl","payroll","monthlyclose","cashregister","documents"]);
  const [period, setPeriod] = useState("mtd");
  // Phase 3 (entity hierarchy): which entity the Financials views are scoped
  // to. Persists in URL so refresh restores; default = Personal (root of tree).
  // See operational_rule "Financials module scope: hierarchical entity tree".
  const [entity, setEntity] = useTabParam("entity", PERSONAL_ROOT_ENTITY_ID);
  const { data: liveData, loading, reload } = useFinancialsData(entity);
  if (liveData) MOCK = liveData;

  const viewSections = [
    { id: "overview",  label: "Overview"        },
    { id: "pl",        label: "P&L"             },
    { id: "comp",      label: "Comp Recap"      },
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
      <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", marginBottom: 16, flexWrap: "wrap", gap: 10 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900, letterSpacing: "-0.02em" }}>Financials</div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 3 }}>
            Cash basis · Calendar year · All figures in USD
          </div>
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }} className="newtworks-no-print">
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
      {section === "pl"       && (
        <PLSection
          data={MOCK}
          onDataChanged={reload}
          entity={entity}
          setEntity={setEntity}
          breadcrumb={MOCK?.entityContext?.breadcrumb || []}
          directChildren={MOCK?.entityContext?.directChildren || []}
        />
      )}
      {section === "comp"     && <CompRecapSection data={MOCK} />}
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
