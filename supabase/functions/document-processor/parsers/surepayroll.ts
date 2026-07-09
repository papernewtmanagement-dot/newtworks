// =========================================================================
// parsers/surepayroll.ts
// =========================================================================
// SurePayroll (State Farm-forwarded) payroll summary parser.
// Deterministic regex — no LLM. Handles unpdf's specific output format
// (right-to-left reading, no whitespace between amounts and labels).
// Writes payroll_runs + payroll_detail with full jsonb per-item breakdowns,
// denormalizes into weekly_cpr_team_detail for the CPR week ending the first
// Saturday >= check_date, auto-resolves pending payroll_run alerts, stars the
// source email. Consolidated from standalone `payroll-email-parser` v9 (2026-07-07).
// =========================================================================

import { sb } from "../lib/supabase.ts";
import { callComposio } from "../lib/composio.ts";

interface SPItem { period: number; ytd: number; hours?: number; }
interface SPEmployeeBlock {
  last_name: string; first_name: string; income_state: string;
  net_pay: number; period_gross: number; ytd_gross: number;
  period_hours: number | null;
  earnings_items: Record<string, SPItem>;
  deduction_items: Record<string, SPItem>;
  employer_items: Record<string, SPItem>;
}
interface ParsedSurePayroll {
  employer_entity_name: string; pay_period_start: string; pay_period_end: string;
  check_date: string; transmit_date: string | null;
  employees: SPEmployeeBlock[];
  totals: { period_gross: number; period_employee_taxes: number; period_employee_deductions: number; period_employer_taxes: number; net_pay: number; total_cash_requirement: number; };
}

const SP_MONTH_LOOKUP: Record<string, number> = { Jan:1,Feb:2,Mar:3,Apr:4,May:5,Jun:6,Jul:7,Aug:8,Sep:9,Oct:10,Nov:11,Dec:12 };

function spParseMoney(s: string): number {
  const clean = s.replace(/[,$\s]/g, "").trim();
  const neg = clean.endsWith("-");
  const n = parseFloat(neg ? clean.slice(0, -1) : clean);
  return isNaN(n) ? 0 : (neg ? -n : n);
}
function spDateToNum(m: string, d: number, y: number): number { return y * 10000 + SP_MONTH_LOOKUP[m] * 100 + d; }
function spToIso(m: string, d: number, y: number): string { return `${y}-${String(SP_MONTH_LOOKUP[m]).padStart(2, "0")}-${String(d).padStart(2, "0")}`; }

const SP_DEDUCTION_LABELS = new Set(["FED WTH", "FICA", "MEDFICA", "DENTAL", "MEDICAL", "VISION", "MISC 1T", "VACHILD"]);
const SP_EMPLOYER_LABELS = new Set(["CO FICA", "CO MEDC", "FUTA", "TX ETIA", "TXEMPL", "FEES"]);

function spClassifyLabel(label: string): "deduction" | "employer" | "earning" {
  if (SP_DEDUCTION_LABELS.has(label) || /^STATE-[A-Z]{2}$/.test(label)) return "deduction";
  if (SP_EMPLOYER_LABELS.has(label) || /^CO UNEM-[A-Z]{2}$/.test(label)) return "employer";
  return "earning";
}

export function parseSurePayrollText(text: string): ParsedSurePayroll {
  if (!/PAPERNEWT\s+LLC/i.test(text) || !/Payroll\s+Summary/i.test(text)) {
    throw new Error("PDF does not look like a PAPERNEWT SurePayroll summary");
  }
  const dateRe = /([A-Z][a-z]{2})\s+(\d{1,2}),\s+(\d{4})/g;
  const dates: Array<{ m: string; d: number; y: number; num: number }> = [];
  let dm: RegExpExecArray | null;
  while ((dm = dateRe.exec(text)) !== null) {
    dates.push({ m: dm[1], d: parseInt(dm[2], 10), y: parseInt(dm[3], 10), num: spDateToNum(dm[1], parseInt(dm[2], 10), parseInt(dm[3], 10)) });
  }
  const uniq = Array.from(new Map(dates.map(d => [d.num, d])).values()).sort((a, b) => a.num - b.num);
  if (uniq.length < 3) throw new Error(`Only ${uniq.length} unique dates found; need 3+`);
  const pay_period_start = spToIso(uniq[0].m, uniq[0].d, uniq[0].y);
  const pay_period_end = spToIso(uniq[1].m, uniq[1].d, uniq[1].y);
  const check_date = spToIso(uniq[2].m, uniq[2].d, uniq[2].y);

  let transmit_date: string | null = null;
  const trM = text.match(/AMOUNT\s+TRANSMITTED\s+ON\s+(\d{2})\/(\d{2})\/(\d{4})/i);
  if (trM) transmit_date = `${trM[3]}-${trM[1]}-${trM[2]}`;

  const totalsIdx = text.indexOf("PAYROLL SUMMARY TOTALS");
  const employeeSection = totalsIdx >= 0 ? text.slice(0, totalsIdx) : text;

  const nameRe = /Unemployment\s+State:\s+[A-Z]{2}\s+([A-Z][A-Z\-\s]+?),\s+([A-Z][A-Z\-\s]+?)\s+EMPLOYER\s+TAXES/g;
  const nameMatches: Array<{ last: string; first: string; index: number; end: number }> = [];
  let nm: RegExpExecArray | null;
  while ((nm = nameRe.exec(employeeSection)) !== null) {
    nameMatches.push({ last: nm[1].trim(), first: nm[2].trim(), index: nm.index, end: nm.index + nm[0].length });
  }

  const totalMarkerRe = /TOTAL:/g;
  const totalPositions: number[] = [];
  let tm: RegExpExecArray | null;
  while ((tm = totalMarkerRe.exec(employeeSection)) !== null) totalPositions.push(tm.index);

  const employees: SPEmployeeBlock[] = [];
  for (let i = 0; i < nameMatches.length; i++) {
    const nameStart = nameMatches[i].index;
    const empTotal = totalPositions.find(p => p > nameStart) ?? employeeSection.length;
    const prevTotal = i > 0 ? (totalPositions.find(p => p > nameMatches[i-1].index) ?? 0) : 0;
    const blockStart = i === 0 ? 0 : prevTotal + "TOTAL:".length;
    const blockEnd = empTotal;
    const block = employeeSection.slice(blockStart, blockEnd);
    employees.push(parseSurePayrollEmployeeBlock(nameMatches[i].last, nameMatches[i].first, block));
  }

  const grandTotalsBlock = totalsIdx >= 0 ? text.slice(totalsIdx) : "";
  const netPayM = grandTotalsBlock.match(/NET\s+PAY\s+\$([\d,]+\.\d{2})/i);
  const totalCashM = grandTotalsBlock.match(/TOTAL\s+CASH\s+REQUIREMENTS\s+\$([\d,]+\.\d{2})/i);
  const eeTaxKeys = ["FED WTH", "FICA", "MEDFICA"];
  const totals = {
    period_gross: employees.reduce((s, e) => s + e.period_gross, 0),
    period_employee_taxes: employees.reduce((s, e) => s + eeTaxKeys.reduce((a, k) => a + (e.deduction_items[k]?.period ?? 0), 0) + Object.entries(e.deduction_items).filter(([k]) => /^STATE-/.test(k)).reduce((a, [, v]) => a + v.period, 0), 0),
    period_employee_deductions: employees.reduce((s, e) => s + Object.entries(e.deduction_items).filter(([k]) => !eeTaxKeys.includes(k) && !/^STATE-/.test(k)).reduce((a, [, v]) => a + v.period, 0), 0),
    period_employer_taxes: employees.reduce((s, e) => s + Object.values(e.employer_items).reduce((a, b) => a + b.period, 0), 0),
    net_pay: netPayM ? spParseMoney(netPayM[1]) : employees.reduce((s, e) => s + e.net_pay, 0),
    total_cash_requirement: totalCashM ? spParseMoney(totalCashM[1]) : 0,
  };
  return { employer_entity_name: "PAPERNEWT LLC", pay_period_start, pay_period_end, check_date, transmit_date, employees, totals };
}

function parseSurePayrollEmployeeBlock(last: string, first: string, block: string): SPEmployeeBlock {
  const emp: SPEmployeeBlock = {
    last_name: last, first_name: first, income_state: "",
    net_pay: 0, period_gross: 0, ytd_gross: 0, period_hours: null,
    earnings_items: {}, deduction_items: {}, employer_items: {},
  };
  const stM = block.match(/Income\s+Tax\s+State:\s+([A-Z]{2})/);
  if (stM) emp.income_state = stM[1];
  const npM = block.match(/NET\s+PAY\s+Direct\s+Deposit\s+\$([\d,]+\.\d{2})/i);
  if (npM) emp.net_pay = spParseMoney(npM[1]);

  const netPayStart = npM ? block.indexOf(npM[0]) : -1;
  const netPayEnd = npM ? netPayStart + npM[0].length : -1;

  const dollarRe = /\$(-?[\d,]+\.\d{2})/g;
  const dollars: Array<{ index: number; value: number }> = [];
  let dm: RegExpExecArray | null;
  while ((dm = dollarRe.exec(block)) !== null) {
    if (dm.index >= netPayStart && dm.index < netPayEnd) continue;
    dollars.push({ index: dm.index, value: spParseMoney(dm[1]) });
  }
  if (dollars.length > 0) {
    let biggestIdx = 0;
    for (let i = 1; i < dollars.length; i++) if (dollars[i].value > dollars[biggestIdx].value) biggestIdx = i;
    emp.ytd_gross = dollars[biggestIdx].value;
    emp.period_gross = biggestIdx + 1 < dollars.length ? dollars[biggestIdx + 1].value : 0;
  }

  const tripleRe = /\$(-?[\d,]+\.\d{2})\$(-?[\d,]+\.\d{2})([^$]+?)(?=\$|\s*$)/g;
  let m: RegExpExecArray | null;
  while ((m = tripleRe.exec(block)) !== null) {
    const ytd = spParseMoney(m[1]);
    const per = spParseMoney(m[2]);
    const raw = m[3];
    let hours: number | undefined = undefined;
    let label = raw.trim();
    const hm = raw.match(/^(\d{1,3}\.\d{2})([A-Za-z\-].+)$/);
    if (hm) { hours = parseFloat(hm[1]); label = hm[2].trim(); }
    label = label.replace(/\s+/g, " ").trim();
    if (!label || /^\d+\.\d{2}$/.test(label) || label === "TOTAL:" || label.endsWith("TOTAL:") || label.includes("TOTAL:")) continue;
    if (/^(EMPLOYER|EMPLOYEE|EARNINGS|VALUES|ITEM|PERIOD|YTD|NET PAY|Income|Unemployment|Report)/i.test(label)) continue;
    const kind = spClassifyLabel(label);
    const item: SPItem = { period: per, ytd };
    if (hours !== undefined) item.hours = hours;
    if (kind === "deduction") emp.deduction_items[label] = item;
    else if (kind === "employer") emp.employer_items[label] = item;
    else {
      emp.earnings_items[label] = item;
      if (hours !== undefined && emp.period_hours === null) emp.period_hours = hours;
    }
  }
  return emp;
}

async function spMatchTeamMember(last: string, first: string): Promise<{ id: string; agency_id: string | null } | null> {
  const { data, error } = await sb.from("team").select("id, agency_id").ilike("last_name", last).ilike("first_name", first).maybeSingle();
  if (error || !data) return null;
  return { id: data.id, agency_id: data.agency_id };
}

function spTargetCprWeekEnding(checkDate: string): string {
  const d = new Date(checkDate + "T00:00:00Z");
  const dow = d.getUTCDay();
  d.setUTCDate(d.getUTCDate() + ((6 - dow + 7) % 7));
  return d.toISOString().slice(0, 10);
}

interface SPProcessResult {
  ok: boolean;
  error?: string;
  payroll_run_id?: string;
  merged_existing?: boolean;
  employees_written?: number;
  unmatched_employees?: string[];
  cpr_week_updated?: string;
  alerts_resolved?: number;
}

export async function processSurePayrollPdf(opts: {
  agencyId: string;
  documentId: string;
  gmailMessageId: string;
  gmailThreadId: string;
  pdfText: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
}): Promise<SPProcessResult> {
  let parsed: ParsedSurePayroll;
  try { parsed = parseSurePayrollText(opts.pdfText); }
  catch (e) { return { ok: false, error: `parser: ${(e as Error).message}` }; }

  const { data: entity } = await sb.from("business_entities").select("id, entity_name").ilike("entity_name", "PaperNewt%").maybeSingle();
  const businessEntityId = entity?.id ?? null;

  const { data: existingByPeriod } = await sb.from("payroll_runs").select("id").eq("agency_id", opts.agencyId).eq("pay_period_end", parsed.pay_period_end).maybeSingle();

  const runFields = {
    agency_id: opts.agencyId, business_entity_id: businessEntityId,
    pay_period_start: parsed.pay_period_start, pay_period_end: parsed.pay_period_end,
    pay_date: parsed.check_date, transmit_date: parsed.transmit_date,
    payroll_provider: "SurePayroll",
    gross_payroll: parsed.totals.period_gross, employer_taxes: parsed.totals.period_employer_taxes, net_payroll: parsed.totals.net_pay,
    total_employee_taxes: parsed.totals.period_employee_taxes, total_employer_taxes: parsed.totals.period_employer_taxes,
    total_employee_deductions: parsed.totals.period_employee_deductions, total_cash_requirement: parsed.totals.total_cash_requirement,
    status: "imported", gmail_message_id: opts.gmailMessageId, gmail_thread_id: opts.gmailThreadId,
    source_document_id: opts.documentId,
    raw_pdf_text: opts.pdfText.slice(0, 20000), parsed_at: new Date().toISOString(),
    notes: `Auto-ingested via document-processor SurePayroll parser. ${parsed.employees.length} employees.`,
  };

  let runRowId: string;
  let mergedExisting = false;
  if (existingByPeriod?.id) {
    const { error: updErr } = await sb.from("payroll_runs").update(runFields).eq("id", existingByPeriod.id);
    if (updErr) return { ok: false, error: `payroll_runs update: ${updErr.message}` };
    runRowId = existingByPeriod.id;
    mergedExisting = true;
  } else {
    const { data: runRow, error: runErr } = await sb.from("payroll_runs").insert(runFields).select("id").single();
    if (runErr || !runRow) {
      if ((runErr as any)?.code === "23505") return { ok: false, error: "unique constraint violation (concurrent write?)" };
      return { ok: false, error: `payroll_runs insert: ${runErr?.message}` };
    }
    runRowId = runRow.id;
  }

  const unmatched: string[] = [];
  const detailRows: any[] = [];
  const cprBreakdownByTeamId: Record<string, any> = {};
  const eeTaxKeys = ["FED WTH", "FICA", "MEDFICA"];

  for (const e of parsed.employees) {
    const match = await spMatchTeamMember(e.last_name, e.first_name);
    if (!match) { unmatched.push(`${e.first_name} ${e.last_name}`); continue; }

    const stateTax = Object.entries(e.deduction_items).filter(([k]) => /^STATE-/.test(k)).reduce((s, [, v]) => s + v.period, 0);
    const otherDed = Object.entries(e.deduction_items).filter(([k]) => !eeTaxKeys.includes(k) && !/^STATE-/.test(k)).reduce((s, [, v]) => s + v.period, 0);
    const employerSum = Object.values(e.employer_items).reduce((s, v) => s + v.period, 0);

    const earningsPeriodTotal = Object.values(e.earnings_items).reduce((s, v) => s + v.period, 0);
    const earningsYtdTotal    = Object.values(e.earnings_items).reduce((s, v) => s + v.ytd, 0);
    const dedPeriodTotal      = Object.values(e.deduction_items).reduce((s, v) => s + v.period, 0);
    const dedYtdTotal         = Object.values(e.deduction_items).reduce((s, v) => s + v.ytd, 0);
    const empPeriodTotal      = Object.values(e.employer_items).reduce((s, v) => s + v.period, 0);
    const empYtdTotal         = Object.values(e.employer_items).reduce((s, v) => s + v.ytd, 0);

    detailRows.push({
      payroll_run_id: runRowId, agency_id: opts.agencyId, business_entity_id: businessEntityId, team_member_id: match.id,
      gross_pay: e.period_gross, federal_tax: e.deduction_items["FED WTH"]?.period ?? 0, state_tax: stateTax,
      social_security: e.deduction_items["FICA"]?.period ?? 0, medicare: e.deduction_items["MEDFICA"]?.period ?? 0,
      other_deductions: otherDed, net_pay: e.net_pay, employment_type: "W2",
      ytd_gross: e.ytd_gross, employer_taxes: employerSum,
      raw_earnings: { state: e.income_state, period_hours: e.period_hours, items: e.earnings_items, period_total: earningsPeriodTotal, ytd_total: earningsYtdTotal },
      raw_deductions: { items: e.deduction_items, period_total: dedPeriodTotal, ytd_total: dedYtdTotal },
      raw_employer_taxes: { items: e.employer_items, period_total: empPeriodTotal, ytd_total: empYtdTotal },
    });

    if (match.agency_id === opts.agencyId) {
      cprBreakdownByTeamId[match.id] = {
        period_hours: e.period_hours,
        items: e.earnings_items,
        period_total: earningsPeriodTotal,
        ytd_total: earningsYtdTotal,
      };
    }
  }
  if (detailRows.length > 0) {
    const { error: detErr } = await sb.from("payroll_detail").upsert(detailRows, { onConflict: "payroll_run_id,team_member_id", ignoreDuplicates: false });
    if (detErr) return { ok: false, error: `payroll_detail upsert: ${detErr.message}`, payroll_run_id: runRowId };
  }

  const cprWeekEnd = spTargetCprWeekEnding(parsed.check_date);
  const { data: cprReport } = await sb.from("weekly_cpr_reports").select("id").eq("agency_id", opts.agencyId).eq("week_ending_date", cprWeekEnd).maybeSingle();
  if (cprReport?.id) {
    for (const [teamMemberId, breakdown] of Object.entries(cprBreakdownByTeamId)) {
      const ytdGross = (breakdown as any).ytd_total;
      await sb.from("weekly_cpr_team_detail").update({
        payroll_ytd_paid: ytdGross,
        payroll_ytd_breakdown: breakdown,
      }).eq("agency_id", opts.agencyId).eq("weekly_cpr_report_id", cprReport.id).eq("team_member_id", teamMemberId);
    }
  }

  const { data: alertsResolved } = await sb.from("alerts").update({ is_resolved: true, resolved_at: new Date().toISOString() }).eq("agency_id", opts.agencyId).eq("module_reference", "payroll_run").eq("is_resolved", false).lte("due_date", parsed.check_date).select("id");

  await callComposio({
    apiKey: opts.composioApiKey, userId: opts.composioUserId, connectedAccountId: opts.gmailAccountId,
    toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL",
    toolArguments: { message_id: opts.gmailMessageId, add_label_ids: ["STARRED"], user_id: "me" },
  }).catch(() => {});

  return {
    ok: true, payroll_run_id: runRowId, merged_existing: mergedExisting,
    employees_written: detailRows.length, unmatched_employees: unmatched,
    cpr_week_updated: cprReport?.id ? cprWeekEnd : undefined,
    alerts_resolved: alertsResolved?.length ?? 0,
  };
}
