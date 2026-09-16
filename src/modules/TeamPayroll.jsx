import { Fragment, useState, useEffect, useCallback, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { fmtMoney } from "../lib/format.jsx";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { currentWeekSaturdayCT, addDaysISO } from "../lib/weeks.js";

// ─── Payroll ──────────────────────────────────────────────────
// The old Payroll Process manual page, moved into the Team module (Peter
// 2026-09-14) and condensed into one table (Peter 2026-09-15). One row per
// person is one person's pay entry, left to right in the order it gets typed:
// hours, pay for the week, the five bonus codes, the life stipend, the total,
// then what comes out. Open a row for the day-by-day
// hours, that person's paid days off, and their live benefit and deduction
// lines. The written steps are all still here, in the notes below the table.
//
// This page computes nothing. Every figure comes from one function,
// team_payroll_week, for whichever week is picked at the top (Sunday to
// Saturday, Central). Once the payroll summary for a week arrives, that function
// switches every money column over to the frozen paycheck line items, which is
// the same source the CPR pool math reads, so the two pages can never disagree
// about a week that has been paid. Worked hours inside it come from get_weekly_cpr_hours,
// the same function the CPR reads, so the payroll tab and the CPR can never
// show different numbers. The picked week and the opened row both live in the
// URL (pweek, pperson), so a refresh or a new tab lands in the same place. The
// week comes from lib/weeks.js, never from the browser clock.

const LINE_TYPES = [
  { id: "life_stipend",    label: "Life stipend (income, not a deduction)" },
  { id: "medical",         label: "Medical deduction" },
  { id: "dental",          label: "Dental deduction" },
  { id: "vision",          label: "Vision deduction" },
  { id: "other_deduction", label: "Other deduction" },
];

const DAYS = [
  { id: "mon", label: "Mon" },
  { id: "tue", label: "Tue" },
  { id: "wed", label: "Wed" },
  { id: "thu", label: "Thu" },
  { id: "fri", label: "Fri" },
];

// The five payroll codes in use since 2026-07-11.
const CODES = [
  { code: "1Comm",   note: "Commission" },
  { code: "2Team",   note: "Team bonus" },
  { code: "3Market", note: "Marketing" },
  { code: "4Goals",  note: "Goals" },
  { code: "5Manage", note: "Manager" },
];

const COL_COUNT = 13;

const CARD = { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: "14px 16px", marginBottom: 14 };
const H = { fontSize: 13, fontWeight: 700, color: T.slate900, margin: "0 0 8px 0" };
const LI = { fontSize: 13, color: T.slate700, lineHeight: 1.6, margin: "0 0 4px 0" };
const UL = { fontSize: 13, color: T.slate700, lineHeight: 1.6, margin: "0 0 4px 0", paddingLeft: 20 };
const BULLET = { margin: "0 0 4px 0" };
const INPUT = { padding: "6px 8px", fontSize: 12, border: `1px solid ${T.slate200}`, borderRadius: 6, width: "100%" };
const BTN = { padding: "6px 12px", fontSize: 12, fontWeight: 600, borderRadius: 7, border: "none", cursor: "pointer" };
const ARROW = { ...BTN, background: T.slate100, color: T.slate700, padding: "7px 12px", fontSize: 14, lineHeight: 1 };
const ARROW_OFF = { ...ARROW, color: T.slate200, cursor: "default" };
const SELECT = { ...INPUT, width: "auto", maxWidth: "100%" };
const TABLE_WRAP = { overflowX: "auto", WebkitOverflowScrolling: "touch" };
const TH = { fontSize: 11, fontWeight: 700, color: T.slate500, textAlign: "left", padding: "6px 10px 6px 0", whiteSpace: "nowrap" };
const THR = { ...TH, textAlign: "right" };
const TD = { fontSize: 13, color: T.slate700, padding: "6px 10px 6px 0", whiteSpace: "nowrap", boxSizing: "border-box" };
const TDR = { ...TD, textAlign: "right" };
const MUTED = { fontSize: 12, color: T.slate500 };

function money(n) {
  return fmtMoney(n, { decimals: 2 });
}

// Zero reads as nothing to type, so show a dash instead of $0.00.
function money0(n) {
  const v = Number(n);
  if (!Number.isFinite(v) || v === 0) return "—";
  return money(v);
}

function hrs(n) {
  const v = Number(n);
  if (!Number.isFinite(v) || v === 0) return "—";
  return `${Math.round(v * 100) / 100}`;
}

function dayLabel(iso) {
  if (!iso) return "";
  const d = new Date(`${iso}T00:00:00`);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
}

function monthLabel(iso) {
  if (!iso) return "";
  const d = new Date(`${iso}T00:00:00`);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString("en-US", { month: "long", year: "numeric" });
}

function weekLabel(startIso, endIso) {
  if (!startIso || !endIso) return "";
  const a = new Date(`${startIso}T00:00:00`);
  const b = new Date(`${endIso}T00:00:00`);
  if (Number.isNaN(a.getTime()) || Number.isNaN(b.getTime())) return `${startIso} to ${endIso}`;
  const opts = { month: "short", day: "numeric" };
  return `${a.toLocaleDateString("en-US", opts)} to ${b.toLocaleDateString("en-US", opts)}`;
}

// The week-ending Saturdays to choose from, newest first. Sunday to Saturday in
// Central, the same boundary every other week-bounded figure in Newtworks uses.
const WEEKS_TO_OFFER = 27;

function buildWeekOptions() {
  const thisSat = currentWeekSaturdayCT();
  const out = [];
  for (let i = 0; i < WEEKS_TO_OFFER; i++) {
    const end = addDaysISO(thisSat, -i * 7);
    const start = addDaysISO(end, -6);
    const tag = i === 0 ? " · this week" : i === 1 ? " · last week" : "";
    out.push({ id: end, label: `${weekLabel(start, end)}${tag}` });
  }
  return out;
}

function typeLabel(id) {
  const hit = LINE_TYPES.find((t) => t.id === id);
  return hit ? hit.label : id;
}

function num(n) {
  const v = Number(n);
  return Number.isFinite(v) ? v : 0;
}

function LineEditor({ personId, line, onDone, onCancel }) {
  const [form, setForm] = useState({
    line_type: line?.line_type || "medical",
    label: line?.label || "",
    weekly_amount: line?.weekly_amount ?? "",
    monthly_premium: line?.monthly_premium ?? "",
    notes: line?.notes || "",
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  const save = async () => {
    setSaving(true);
    setError(null);
    const { error: e } = await supabase.rpc("team_payroll_line_save", {
      p_team_member_id: personId,
      p_line_type: form.line_type,
      p_label: form.label || null,
      p_weekly_amount: form.weekly_amount === "" ? 0 : Number(form.weekly_amount),
      p_monthly_premium: form.monthly_premium === "" ? null : Number(form.monthly_premium),
      p_agency_paid_weekly: null,
      p_notes: form.notes || null,
      p_id: line?.id || null,
    });
    setSaving(false);
    if (e) { setError(e.message); return; }
    onDone();
  };

  return (
    <div style={{ background: T.slate100, borderRadius: 8, padding: 10, marginTop: 8, display: "grid", gap: 8 }}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 8 }}>
        <label style={{ fontSize: 11, color: T.slate500 }}>
          What it is
          <select style={INPUT} value={form.line_type} onChange={(ev) => setForm({ ...form, line_type: ev.target.value })}>
            {LINE_TYPES.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
          </select>
        </label>
        <label style={{ fontSize: 11, color: T.slate500 }}>
          Name on the pay stub
          <input style={INPUT} value={form.label} onChange={(ev) => setForm({ ...form, label: ev.target.value })} placeholder="Life insurance stipend" />
        </label>
        <label style={{ fontSize: 11, color: T.slate500 }}>
          Per week
          <input style={INPUT} inputMode="decimal" value={form.weekly_amount} onChange={(ev) => setForm({ ...form, weekly_amount: ev.target.value })} placeholder="43.81" />
        </label>
        <label style={{ fontSize: 11, color: T.slate500 }}>
          Per month, if that is how it is billed
          <input style={INPUT} inputMode="decimal" value={form.monthly_premium} onChange={(ev) => setForm({ ...form, monthly_premium: ev.target.value })} placeholder="189.85" />
        </label>
      </div>
      <input style={INPUT} value={form.notes} onChange={(ev) => setForm({ ...form, notes: ev.target.value })} placeholder="Notes (optional)" />
      {error && <div style={{ color: T.red, fontSize: 12, fontWeight: 600 }}>{error}</div>}
      <div style={{ display: "flex", gap: 8 }}>
        <button style={{ ...BTN, background: T.slate900, color: T.white }} onClick={save} disabled={saving}>
          {saving ? "Saving…" : "Save"}
        </button>
        <button style={{ ...BTN, background: T.slate100, color: T.slate700 }} onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

// One person's benefit and deduction lines, live.
function BenefitLines({ personId, lines, onChanged }) {
  const [editing, setEditing] = useState(null); // line id, or "new"
  const rows = Array.isArray(lines) ? lines : [];

  const remove = async (id) => {
    const { error: e } = await supabase.rpc("team_payroll_line_delete", { p_id: id });
    if (!e) onChanged();
  };

  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
        <div style={{ fontSize: 12, fontWeight: 700, color: T.slate500 }}>Benefits and deductions</div>
        <button style={{ ...BTN, background: T.slate100, color: T.slate700 }} onClick={() => setEditing(editing === "new" ? null : "new")}>
          {editing === "new" ? "Close" : "Add a line"}
        </button>
      </div>
      {!rows.length && editing !== "new" && (
        <div style={{ ...MUTED, marginTop: 4 }}>Nothing on file.</div>
      )}
      {rows.map((l) => (
        <div key={l.id} style={{ marginTop: 6 }}>
          <div style={{ display: "flex", justifyContent: "space-between", gap: 10, fontSize: 12, color: T.slate700, flexWrap: "wrap" }}>
            <div>
              <strong>{l.label || typeLabel(l.line_type)}</strong>
              <span style={{ color: T.slate500 }}> · {typeLabel(l.line_type)}</span>
            </div>
            <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
              <span>{money(l.weekly_amount)} / week</span>
              {l.monthly_premium ? <span style={{ color: T.slate500 }}>({money(l.monthly_premium)} / month)</span> : null}
              <button style={{ ...BTN, background: "transparent", color: T.slate500, padding: "2px 6px" }} onClick={() => setEditing(editing === l.id ? null : l.id)}>Edit</button>
              <button style={{ ...BTN, background: "transparent", color: T.red, padding: "2px 6px" }} onClick={() => remove(l.id)}>Remove</button>
            </div>
          </div>
          {editing === l.id && (
            <LineEditor personId={personId} line={l} onCancel={() => setEditing(null)} onDone={() => { setEditing(null); onChanged(); }} />
          )}
        </div>
      ))}
      {editing === "new" && (
        <LineEditor personId={personId} line={null} onCancel={() => setEditing(null)} onDone={() => { setEditing(null); onChanged(); }} />
      )}
    </div>
  );
}

// What sits under an opened row: the day-by-day hours, the paid days off, and
// the live benefit and deduction lines.
function RowDetail({ row, onChanged }) {
  const days = Array.isArray(row.days) ? row.days : [];
  const daysOff = Array.isArray(row.time_off) ? row.time_off : [];
  const byDay = {};
  days.forEach((d) => { byDay[d.day_label] = d; });
  const hasDays = days.length > 0;

  return (
    <div style={{ background: T.slate50, borderRadius: 8, padding: 12, margin: "2px 0 8px 0", display: "grid", gap: 12 }}>
      {hasDays && (
        <div>
          <div style={{ fontSize: 12, fontWeight: 700, color: T.slate500, marginBottom: 6 }}>Hours by day</div>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(90px, 1fr))", gap: 8 }}>
            {DAYS.map((d) => (
              <div key={d.id} style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 6, padding: "6px 8px", boxSizing: "border-box" }}>
                <div style={{ fontSize: 11, color: T.slate500 }}>{d.label}</div>
                <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{hrs(byDay[d.id]?.hours)}</div>
                {num(byDay[d.id]?.paid_time_off_hours) > 0 && (
                  <div style={{ fontSize: 11, color: T.slate500 }}>{hrs(byDay[d.id]?.paid_time_off_hours)} off</div>
                )}
              </div>
            ))}
          </div>
        </div>
      )}
      <div>
        <div style={{ fontSize: 12, fontWeight: 700, color: T.slate500, marginBottom: 6 }}>Paid time off this week</div>
        {!daysOff.length
          ? <div style={MUTED}>None.</div>
          : (
            <ul style={UL}>
              {daysOff.map((r, i) => (
                <li key={`${r.work_date}-${i}`} style={BULLET}>
                  {dayLabel(r.work_date)} · {r.label} · {hrs(r.hours)} hours
                </li>
              ))}
            </ul>
          )}
      </div>
      <BenefitLines personId={row.team_member_id} lines={row.lines} onChanged={onChanged} />
    </div>
  );
}

// Leslie's monthly goals. The bot asks Marie on the 1st; her answer is what says
// whether the kids' goals were hit, so it belongs next to the bonus numbers.
function LeslieGoals({ goals }) {
  const answered = !!goals?.answered;
  const paid = !!goals?.bonus_paid;
  const dot = { width: 8, height: 8, borderRadius: 8, marginTop: 5, flexShrink: 0, background: answered && paid ? T.green : answered ? T.blue : T.amber, boxSizing: "border-box" };
  return (
    <div style={{ display: "flex", gap: 8, alignItems: "flex-start", marginTop: 12, paddingTop: 10, borderTop: `1px solid ${T.slate200}`, fontSize: 13, color: T.slate700, flexWrap: "wrap" }}>
      <span style={dot} />
      <div style={{ flex: "1 1 240px" }}>
        {!goals
          ? <><strong>Leslie's goals.</strong> No question has gone out yet.</>
          : answered
            ? <><strong>Leslie's goals for {monthLabel(goals.review_month)}.</strong> Marie answered: {goals.marie_reply_text}. {paid ? "Bonus paid." : "Bonus not paid yet."}</>
            : <><strong>Leslie's goals for {monthLabel(goals.review_month)}.</strong> Still waiting on Marie's answer.</>}
      </div>
    </div>
  );
}

// One row per person. One row is one person's pay entry, in the order it gets
// typed: hours, pay, the five codes, what is added in, the total before
// deductions, then what comes out.
function PayrollTable({ rows, hasReport, openId, setOpenId, hrefForPerson, onChanged }) {
  if (!rows.length) return <div style={MUTED}>Nobody to pay this week.</div>;

  const totals = rows.reduce((acc, r) => {
    acc.worked += num(r.worked_hours);
    acc.pto += num(r.paid_time_off_hours);
    acc.overtime += num(r.overtime_hours);
    acc.pay += num(r.pay);
    CODES.forEach((c) => { acc.codes[c.code] += num(r.codes?.[c.code]); });
    acc.addIn += num(r.add_in);
    acc.before += num(r.before_deductions);
    acc.takeOut += num(r.take_out);
    return acc;
  }, {
    worked: 0, pto: 0, overtime: 0, pay: 0, addIn: 0, before: 0, takeOut: 0,
    codes: { "1Comm": 0, "2Team": 0, "3Market": 0, "4Goals": 0, "5Manage": 0 },
  });

  return (
    <div style={TABLE_WRAP}>
      <table style={{ borderCollapse: "collapse", width: "100%" }}>
        <thead>
          <tr>
            <th style={TH}>Who</th>
            <th style={THR}>Worked</th>
            <th style={THR}>PTO</th>
            <th style={THR}>Over 40</th>
            <th style={THR}>Pay</th>
            {CODES.map((c) => <th key={c.code} style={THR} title={c.note}>{c.code}</th>)}
            <th style={THR}>LIFE</th>
            <th style={{ ...THR, color: T.slate900 }}>Total</th>
            <th style={THR}>Take out</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const open = openId === r.team_member_id;
            return (
              <Fragment key={r.team_member_id}>
                <tr style={{ borderTop: `1px solid ${T.slate200}`, background: open ? T.slate50 : undefined }}>
                  <td style={{ ...TD, fontWeight: 600, color: T.slate900 }}>
                    <TabLink
                      href={hrefForPerson(open ? null : r.team_member_id)}
                      onSelect={() => setOpenId(open ? null : r.team_member_id)}
                      style={{ color: T.slate900, textDecoration: "none", fontWeight: 600 }}
                      title={open ? "Close" : "Open the detail"}
                    >
                      {open ? "\u25be " : "\u25b8 "}{r.name}
                    </TabLink>
                  </td>
                  <td style={TDR}>{hrs(r.worked_hours)}</td>
                  <td style={TDR}>{hrs(r.paid_time_off_hours)}</td>
                  <td style={{ ...TDR, color: num(r.overtime_hours) > 0 ? T.amber : T.slate500 }}>{hrs(r.overtime_hours)}</td>
                  <td style={TDR}>{money0(r.pay)}</td>
                  {CODES.map((c) => (
                    <td key={c.code} style={TDR}>{hasReport ? money0(r.codes?.[c.code]) : "\u2014"}</td>
                  ))}
                  <td style={{ ...TDR, color: num(r.add_in) > 0 ? T.green : T.slate500 }}>{money0(r.add_in)}</td>
                  <td style={{ ...TDR, fontWeight: 700, color: T.slate900 }}>{money0(r.before_deductions)}</td>
                  <td style={{ ...TDR, color: num(r.take_out) > 0 ? T.red : T.slate500 }}>{money0(r.take_out)}</td>
                </tr>
                {open && (
                  <tr style={{ background: T.slate50 }}>
                    <td colSpan={COL_COUNT} style={{ padding: 0 }}>
                      <RowDetail row={r} onChanged={onChanged} />
                    </td>
                  </tr>
                )}
              </Fragment>
            );
          })}
          <tr style={{ borderTop: `2px solid ${T.slate200}` }}>
            <td style={{ ...TD, fontWeight: 700, color: T.slate900 }}>Everyone</td>
            <td style={{ ...TDR, fontWeight: 700 }}>{hrs(totals.worked)}</td>
            <td style={{ ...TDR, fontWeight: 700 }}>{hrs(totals.pto)}</td>
            <td style={{ ...TDR, fontWeight: 700 }}>{hrs(totals.overtime)}</td>
            <td style={{ ...TDR, fontWeight: 700 }}>{money0(totals.pay)}</td>
            {CODES.map((c) => (
              <td key={c.code} style={{ ...TDR, fontWeight: 700 }}>{hasReport ? money0(totals.codes[c.code]) : "\u2014"}</td>
            ))}
            <td style={{ ...TDR, fontWeight: 700 }}>{money0(totals.addIn)}</td>
            <td style={{ ...TDR, fontWeight: 700, color: T.slate900 }}>{money0(totals.before)}</td>
            <td style={{ ...TDR, fontWeight: 700 }}>{money0(totals.takeOut)}</td>
          </tr>
        </tbody>
      </table>
    </div>
  );
}

// A badge only when the week is locked, meaning the payroll summary has arrived
// and the figures are frozen at what was actually paid. An unlocked week gets no
// badge at all -- nothing on screen is the signal that it is still moving.
function LockBadge({ locked }) {
  if (!locked) return null;
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 4,
      fontSize: 11, fontWeight: 700, borderRadius: 999, padding: "2px 8px",
      boxSizing: "border-box", whiteSpace: "nowrap",
      background: T.slate100, color: T.slate700,
    }}>
      🔒 Locked · paid
    </span>
  );
}

// The written steps, kept word for word, out of the way until they are wanted.
function Note({ title, children }) {
  return (
    <details style={{ ...CARD, padding: "10px 14px", marginBottom: 8 }}>
      <summary style={{ fontSize: 13, fontWeight: 600, color: T.slate900, cursor: "pointer" }}>{title}</summary>
      <div style={{ marginTop: 8 }}>{children}</div>
    </details>
  );
}

export default function TeamPayroll() {
  const weeks = useMemo(() => buildWeekOptions(), []);
  const weekIds = useMemo(() => weeks.map((w) => w.id), [weeks]);
  const [pickedWeek, setPickedWeek, hrefForWeek] = useTabParam("pweek", weeks[0].id, weekIds);
  const [openId, setOpenId, hrefForPerson] = useTabParam("pperson", null);
  const [week, setWeek] = useState(undefined); // undefined = loading
  const [weekError, setWeekError] = useState(null);

  const loadWeek = useCallback(async () => {
    const { data, error: e } = await supabase.rpc("team_payroll_week", {
      p_agency_id: AGENCY_ID,
      p_week_ending_date: pickedWeek,
    });
    if (e) { setWeekError(e.message); setWeek(null); return; }
    setWeekError(null);
    setWeek(data || null);
  }, [pickedWeek]);

  useEffect(() => { loadWeek(); }, [loadWeek]);

  const rows = Array.isArray(week?.people) ? week.people : [];
  const weekText = week ? weekLabel(week.week_start_date, week.week_ending_date) : "";
  const hasReport = !!week?.has_cpr_report;
  const payrollIn = !!week?.payroll_received;
  const locked = !!week?.lock?.locked;
  const pickedIdx = Math.max(0, weekIds.indexOf(pickedWeek));
  const olderId = pickedIdx + 1 < weeks.length ? weeks[pickedIdx + 1].id : null;
  const newerId = pickedIdx > 0 ? weeks[pickedIdx - 1].id : null;

  return (
    <div>
      <div style={{ display: "flex", alignItems: "center", gap: 6, flexWrap: "wrap", marginBottom: 6 }}>
        <TabLink
          href={olderId ? hrefForWeek(olderId) : "#"}
          onSelect={() => { if (olderId) setPickedWeek(olderId); }}
          disabled={!olderId}
          style={olderId ? ARROW : ARROW_OFF}
          title="Earlier week"
          ariaLabel="Earlier week"
        >
          ‹
        </TabLink>
        <select style={SELECT} value={pickedWeek} onChange={(ev) => setPickedWeek(ev.target.value)}>
          {weeks.map((w) => <option key={w.id} value={w.id}>{w.label}</option>)}
        </select>
        <TabLink
          href={newerId ? hrefForWeek(newerId) : "#"}
          onSelect={() => { if (newerId) setPickedWeek(newerId); }}
          disabled={!newerId}
          style={newerId ? ARROW : ARROW_OFF}
          title="Later week"
          ariaLabel="Later week"
        >
          ›
        </TabLink>
      </div>

      {weekError && <div style={{ color: T.red, fontSize: 12, fontWeight: 600, marginBottom: 10 }}>{weekError}</div>}

      <div style={CARD}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 10, flexWrap: "wrap", marginBottom: 8 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
            <div style={{ ...H, margin: 0 }}>What to enter{weekText ? ` \u00b7 ${weekText}` : ""}</div>
            <LockBadge locked={locked} />
          </div>
          <div style={MUTED}>Open a name for the day-by-day hours, days off and deductions.</div>
        </div>

        {week === undefined
          ? <div style={MUTED}>Loading the week…</div>
          : (
            <>
              <PayrollTable
                rows={rows}
                hasReport={hasReport}
                openId={openId}
                setOpenId={setOpenId}
                hrefForPerson={hrefForPerson}
                onChanged={loadWeek}
              />
              {payrollIn && <div style={{ ...MUTED, marginTop: 8 }}>Payroll for this week has come in. Every figure above is what was actually paid, not what was worked out beforehand.</div>}
              {!hasReport && !payrollIn && <div style={{ ...MUTED, marginTop: 8 }}>No CPR for this week yet, so the bonus columns are empty.</div>}
              <LeslieGoals goals={week?.leslie_goals || null} />
            </>
          )}
      </div>

      <Note title="Hours and time off">
        <div style={LI}>Work out the hours for the week for anyone who is not salaried.</div>
        <ul style={UL}>
          <li style={BULLET}>Time off is booked in the Time Off module, and it comes in two sizes only: a half day is 4 hours, a full day is 8.</li>
          <li style={BULLET}>When the office is closed, that is a day off for everyone unless it has been changed by hand. A closed office replaces any other time off that day, including a day off earned by winning the week.</li>
          <li style={BULLET}>Paid time off shows in the weekly hours total on the CPR under PTO. It never counts toward the 40-hour overtime line.</li>
          <li style={BULLET}>Unpaid time off is not recorded anywhere. Those hours simply do not appear.</li>
          <li style={BULLET}>Someone's last week is paid by hours worked out of 40, not by whole days.</li>
        </ul>
      </Note>

      <Note title="Benefits and deductions">
        <div style={LI}>
          Life stipends are added as income from the dropdown so the benefit is taxed. Medical, dental and vision come out automatically, so just check they are on the right-hand side. Open a name in the table to add, edit or remove someone's lines.
        </div>
        <div style={LI}>Pay is the wages for the week. LIFE is the life stipend. Total is the pay plus the bonuses plus the stipend. Take out is everything else on file for that person, and it comes off after that.</div>
      </Note>

      <Note title="Bonuses and codes">
        <div style={LI}><strong>Leslie:</strong> paid the first Friday of the month, on the first check date.</div>
        <ul style={UL}>
          <li style={BULLET}>4Goals — Leslie's goals</li>
          <li style={BULLET}>$600 a month in kids' goals bonuses: $300 for Goose if goals are hit, $300 for Duck if goals are hit.</li>
        </ul>
        <div style={{ ...LI, marginTop: 10 }}>The codes in use since 11 July. The table already uses them, so there is nothing to look up.</div>
        <ul style={UL}>
          <li style={BULLET}>1Comm — Commission</li>
          <li style={BULLET}>2Team — Team bonus, the sales share and the retention share together</li>
          <li style={BULLET}>3Market — Marketing, which is the spiff money and is already in dollars</li>
          <li style={BULLET}>4Goals — Goals and health together</li>
          <li style={BULLET}>5Manage — Manager</li>
        </ul>
        <div style={{ ...LI, marginTop: 10 }}>Christmas bonus: OT Scorecard × (1 + (Weeks / 100)) × full or part time status.</div>
      </Note>

      <Note title="Reimbursements — check these every payroll">
        <ul style={UL}>
          <li style={BULLET}><strong>Going out:</strong> do we owe anyone for lunches or anything else?</li>
          <li style={BULLET}><strong>Coming in:</strong> does anyone owe us from an advance? If so, take it now as a miscellaneous deduction.</li>
          <li style={BULLET}><strong>Fitbit:</strong> take $25 a week until it is paid off, regardless of bonus, as a deduction. The only exception is if we need to exchange it. Send the agent and the team member a record of the deduction and the remaining balance.</li>
        </ul>
      </Note>
    </div>
  );
}
