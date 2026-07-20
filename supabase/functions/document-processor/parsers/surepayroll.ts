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
export interface ParsedSurePayroll {
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

// =========================================================================
// CSV parser (2026-07-14) — SurePayroll now also delivers per-week CSVs.
// Header row is stable across weeks (verified across 8 files 5/22–7/17).
// Numeric columns only in data rows (no embedded commas), but we tolerate
// quoted fields defensively. CSV carries NO YTD data — YTD backfill happens
// downstream in processSurePayrollParsed by summing prior payroll_detail
// gross_pay rows within the calendar year.
// =========================================================================

function parseCsvLine(line: string): string[] {
  // Handles quoted fields; unquoted fields split on commas.
  const out: string[] = [];
  let cur = "";
  let inQ = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inQ) {
      if (c === '"') {
        if (line[i + 1] === '"') { cur += '"'; i++; } else { inQ = false; }
      } else { cur += c; }
    } else {
      if (c === ",") { out.push(cur); cur = ""; }
      else if (c === '"') { inQ = true; }
      else { cur += c; }
    }
  }
  out.push(cur);
  return out.map(s => s.trim());
}

function mdyToIso(s: string): string {
  // "7/17/2026" -> "2026-07-17"
  const m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (!m) throw new Error(`Bad date: ${s}`);
  return `${m[3]}-${m[1].padStart(2, "0")}-${m[2].padStart(2, "0")}`;
}

function num(s: string | undefined): number {
  if (s === undefined || s === null || s === "") return 0;
  const n = parseFloat(s.replace(/[,$\s]/g, ""));
  return isNaN(n) ? 0 : n;
}

export function parseSurePayrollCsvText(text: string): ParsedSurePayroll {
  // Normalize line endings; drop empty trailing lines
  const lines = text.replace(/\r\n?/g, "\n").split("\n").filter(l => l.trim().length > 0);
  if (lines.length < 2) throw new Error(`CSV has only ${lines.length} line(s); need header + at least one row`);

  const header = parseCsvLine(lines[0]);
  const idx: Record<string, number> = {};
  for (let i = 0; i < header.length; i++) idx[header[i]] = i;

  const need = (col: string): number => {
    if (!(col in idx)) throw new Error(`CSV missing required column: "${col}"`);
    return idx[col];
  };

  // Required columns (fail loudly if header shifts)
  const cFirst    = need("First Name");
  const cLast     = need("Last Name");
  const cUnState  = need("Unemployment State");
  const cInState  = need("Income Tax State");
  const cCheck    = need("Check Date");
  const cPStart   = need("Period Start");
  const cPEnd     = need("Period End");
  const cGross    = need("Gross Wage");
  const cNet      = need("Net Pay");

  // Optional columns — safe fallback to -1 (empty)
  const optIdx = (col: string) => (col in idx ? idx[col] : -1);
  const cHrsReg   = optIdx("Hours - Regular");
  const cHrsOt    = optIdx("Hours - OT");
  const cHrsVac   = optIdx("Hours - Vacation");
  const cHrsSick  = optIdx("Hours - Sick");
  const cHrsOther = optIdx("Hours - Other");
  const cEarnSal  = optIdx("Earning - Salary");
  const cEarnHr   = optIdx("Earning - Hourly");
  const cEarnCom  = optIdx("Earning - Commission");
  const cEarnBon  = optIdx("Earning - Bonus");
  const cEarnOt   = optIdx("Earning - OT");
  const cEarnReim = optIdx("Earning - Reimbursements");
  const cEarnOth  = optIdx("Earning - Other");
  const cBenHea   = optIdx("Employee Benefit - Health");
  const cBenDen   = optIdx("Employee Benefit - Dental");
  const cBenVis   = optIdx("Employee Benefit - Vision");
  const cBen401   = optIdx("Employee Benefit - 401K");
  const cBenHsa   = optIdx("Employee Benefit - HSA");
  const cBenIra   = optIdx("Employee Benefit - IRA");
  const cBenLif   = optIdx("Employee Benefit - Life");
  const cBenFsa   = optIdx("Employee Benefit - FSA");
  const cDedGar   = optIdx("Employee Deduction - Garnishment");
  const cDedOth   = optIdx("Employee Deduction - Other");
  const cTaxDis   = optIdx("Employee Tax - Disability");
  const cTaxFed   = optIdx("Employee Tax - FED WTH");
  const cTaxFica  = optIdx("Employee Tax - FICA");
  const cTaxMed   = optIdx("Employee Tax - MEDFICA");
  const cTaxSt    = optIdx("Employee Tax - State");
  const cTaxOth   = optIdx("Employee Tax - Other");
  const cErFica   = optIdx("Employer Tax - FICA");
  const cErMed    = optIdx("Employer Tax - MEDC");
  const cErUnem   = optIdx("Employer Tax - Unemployment");
  const cErTaxOth = optIdx("Employer Tax - Other");
  const cErDed    = optIdx("Employer Deductions");

  const getStr = (row: string[], i: number): string => (i >= 0 && i < row.length ? row[i] : "");
  const getNum = (row: string[], i: number): number => num(getStr(row, i));

  const employees: SPEmployeeBlock[] = [];
  const checkDates: string[] = [];
  const periodStarts: string[] = [];
  const periodEnds: string[] = [];

  for (let li = 1; li < lines.length; li++) {
    const row = parseCsvLine(lines[li]);
    if (row.length < 6) continue; // skip incomplete lines defensively

    const first = getStr(row, cFirst).trim();
    const last  = getStr(row, cLast).trim();
    if (!first || !last) continue;

    checkDates.push(mdyToIso(getStr(row, cCheck)));
    periodStarts.push(mdyToIso(getStr(row, cPStart)));
    periodEnds.push(mdyToIso(getStr(row, cPEnd)));

    const inState  = getStr(row, cInState).toUpperCase();
    const unState  = getStr(row, cUnState).toUpperCase();

    const hrsReg   = getNum(row, cHrsReg);
    const hrsOt    = getNum(row, cHrsOt);
    const hrsVac   = getNum(row, cHrsVac);
    const hrsSick  = getNum(row, cHrsSick);
    const hrsOther = getNum(row, cHrsOther);

    const earnSal  = getNum(row, cEarnSal);
    const earnHr   = getNum(row, cEarnHr);
    const earnCom  = getNum(row, cEarnCom);
    const earnBon  = getNum(row, cEarnBon);
    const earnOt   = getNum(row, cEarnOt);
    const earnReim = getNum(row, cEarnReim);
    const earnOth  = getNum(row, cEarnOth);

    const emp: SPEmployeeBlock = {
      first_name: first,
      last_name: last,
      income_state: inState,
      net_pay: getNum(row, cNet),
      period_gross: getNum(row, cGross),
      ytd_gross: 0, // CSV has no YTD; downstream backfill computes it
      period_hours: hrsReg + hrsOt, // productive hours; vacation/sick/other tracked separately
      earnings_items: {
        SALARY:         { period: earnSal,  ytd: 0, hours: earnSal > 0 ? hrsReg : 0 },
        HOURLY:         { period: earnHr,   ytd: 0, hours: earnHr  > 0 ? hrsReg : 0 },
        COMMISSION:     { period: earnCom,  ytd: 0 },
        BONUS:          { period: earnBon,  ytd: 0 },
        OT:             { period: earnOt,   ytd: 0, hours: hrsOt },
        REIMBURSEMENTS: { period: earnReim, ytd: 0 },
        OTHER:          { period: earnOth,  ytd: 0 },
        VACATION_HRS:   { period: 0,        ytd: 0, hours: hrsVac },
        SICK_HRS:       { period: 0,        ytd: 0, hours: hrsSick },
        OTHER_HRS:      { period: 0,        ytd: 0, hours: hrsOther },
      },
      deduction_items: {
        HEALTH:      { period: getNum(row, cBenHea), ytd: 0 },
        DENTAL:      { period: getNum(row, cBenDen), ytd: 0 },
        VISION:      { period: getNum(row, cBenVis), ytd: 0 },
        "401K":      { period: getNum(row, cBen401), ytd: 0 },
        HSA:         { period: getNum(row, cBenHsa), ytd: 0 },
        IRA:         { period: getNum(row, cBenIra), ytd: 0 },
        LIFE:        { period: getNum(row, cBenLif), ytd: 0 },
        FSA:         { period: getNum(row, cBenFsa), ytd: 0 },
        GARNISHMENT: { period: getNum(row, cDedGar), ytd: 0 },
        OTHER_DED:   { period: getNum(row, cDedOth), ytd: 0 },
        DISABILITY:  { period: getNum(row, cTaxDis), ytd: 0 },
        "FED WTH":   { period: getNum(row, cTaxFed), ytd: 0 },
        FICA:        { period: getNum(row, cTaxFica), ytd: 0 },
        MEDFICA:     { period: getNum(row, cTaxMed), ytd: 0 },
        TAX_OTHER:   { period: getNum(row, cTaxOth), ytd: 0 },
        [`STATE-${inState || "XX"}`]: { period: getNum(row, cTaxSt), ytd: 0 },
      },
      employer_items: {
        "CO FICA":                    { period: getNum(row, cErFica),  ytd: 0 },
        "CO MEDC":                    { period: getNum(row, cErMed),   ytd: 0 },
        [`CO UNEM-${unState || "XX"}`]: { period: getNum(row, cErUnem),  ytd: 0 },
        ER_OTHER:                     { period: getNum(row, cErTaxOth),ytd: 0 },
        ER_DED:                       { period: getNum(row, cErDed),   ytd: 0 },
      },
    };
    employees.push(emp);
  }

  if (employees.length === 0) throw new Error("CSV had header but no valid employee rows");

  // Compute totals (mirror the PDF path exactly)
  const eeTaxKeys = ["FED WTH", "FICA", "MEDFICA"];
  const totals = {
    period_gross: employees.reduce((s, e) => s + e.period_gross, 0),
    period_employee_taxes: employees.reduce((s, e) =>
      s + eeTaxKeys.reduce((a, k) => a + (e.deduction_items[k]?.period ?? 0), 0)
        + Object.entries(e.deduction_items).filter(([k]) => /^STATE-/.test(k)).reduce((a, [, v]) => a + v.period, 0), 0),
    period_employee_deductions: employees.reduce((s, e) =>
      s + Object.entries(e.deduction_items).filter(([k]) => !eeTaxKeys.includes(k) && !/^STATE-/.test(k)).reduce((a, [, v]) => a + v.period, 0), 0),
    period_employer_taxes: employees.reduce((s, e) =>
      s + Object.values(e.employer_items).reduce((a, b) => a + b.period, 0), 0),
    net_pay: employees.reduce((s, e) => s + e.net_pay, 0),
    total_cash_requirement: 0, // not present in CSV
  };

  // Dates: min start, max end, max check (rows all share the same values in observed CSVs)
  const minStart = periodStarts.sort()[0];
  const maxEnd = periodEnds.sort().reverse()[0];
  const maxCheck = checkDates.sort().reverse()[0];

  return {
    employer_entity_name: "PAPERNEWT LLC",
    pay_period_start: minStart,
    pay_period_end: maxEnd,
    check_date: maxCheck,
    transmit_date: null, // not in CSV
    employees,
    totals,
  };
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

export async function processSurePayrollParsed(opts: {
  agencyId: string;
  documentId: string;
  gmailMessageId: string;
  gmailThreadId: string;
  parsed: ParsedSurePayroll;
  sourceText: string;          // stored in raw_pdf_text for audit (legacy column name)
  sourceFormat: "pdf" | "csv"; // shapes the notes field + YTD-backfill branch
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
}): Promise<SPProcessResult> {
  const parsed = opts.parsed;

  // Payroll records live under PaperNewt LLC (W-2 employer of record).
  // Cash movement JEs stay on Peter Story State Farm. (2026-07-15 decision)
  const businessEntityId = "b1111111-1111-1111-1111-111111111111";

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
    raw_pdf_text: opts.sourceText.slice(0, 20000), parsed_at: new Date().toISOString(),
    notes: `Auto-ingested via document-processor SurePayroll ${opts.sourceFormat.toUpperCase()} parser. ${parsed.employees.length} employees.`,
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

    // YTD backfill: PDF path carries per-item YTD from the source. CSV path
    // does not — we compute cumulative YTD gross from prior payroll_detail rows
    // in the same calendar year (excluding this run itself). Downstream columns
    // driven by ytd_total (weekly_cpr_team_detail.payroll_ytd_paid) require this.
    let effectiveYtdGross = e.ytd_gross;
    let effectiveEarningsYtd = earningsYtdTotal;
    if (opts.sourceFormat === "csv" || effectiveYtdGross === 0) {
      const yearStart = `${parsed.check_date.slice(0, 4)}-01-01`;
      const { data: priorRows } = await sb
        .from("payroll_detail")
        .select("gross_pay, payroll_runs!inner(pay_date)")
        .eq("team_member_id", match.id)
        .eq("agency_id", opts.agencyId)
        .gte("payroll_runs.pay_date", yearStart)
        .lt("payroll_runs.pay_date", parsed.check_date);
      const priorGross = (priorRows ?? []).reduce((s: number, r: any) => s + parseFloat(r.gross_pay ?? 0), 0);
      effectiveYtdGross = Math.round((priorGross + e.period_gross) * 100) / 100;
      effectiveEarningsYtd = effectiveYtdGross; // matches item-sum semantics
    }

    detailRows.push({
      payroll_run_id: runRowId, agency_id: opts.agencyId, business_entity_id: businessEntityId, team_member_id: match.id,
      gross_pay: e.period_gross, federal_tax: e.deduction_items["FED WTH"]?.period ?? 0, state_tax: stateTax,
      social_security: e.deduction_items["FICA"]?.period ?? 0, medicare: e.deduction_items["MEDFICA"]?.period ?? 0,
      other_deductions: otherDed, net_pay: e.net_pay, employment_type: "W2",
      ytd_gross: effectiveYtdGross, employer_taxes: employerSum,
      raw_earnings: { state: e.income_state, period_hours: e.period_hours, items: e.earnings_items, period_total: earningsPeriodTotal, ytd_total: effectiveEarningsYtd },
      raw_deductions: { items: e.deduction_items, period_total: dedPeriodTotal, ytd_total: dedYtdTotal },
      raw_employer_taxes: { items: e.employer_items, period_total: empPeriodTotal, ytd_total: empYtdTotal },
    });

    if (match.agency_id === opts.agencyId) {
      cprBreakdownByTeamId[match.id] = {
        period_hours: e.period_hours,
        items: e.earnings_items,
        period_total: earningsPeriodTotal,
        ytd_total: effectiveEarningsYtd,
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

  // Fix 2026-07-20: module_reference is stored as "payroll_run:<pay_period_end>"
  // (per payroll_weekly_nag), not the bare literal "payroll_run" this code
  // previously matched — the .eq comparison never hit anything, so alerts
  // stayed open silently after every successful import. Match on the exact
  // pay_period_end this ingest closes.
  const { data: alertsResolved } = await sb.from("alerts").update({ is_resolved: true, resolved_at: new Date().toISOString() }).eq("agency_id", opts.agencyId).eq("module_reference", `payroll_run:${parsed.pay_period_end}`).eq("is_resolved", false).select("id");

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
