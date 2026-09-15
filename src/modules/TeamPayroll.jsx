import { useState, useEffect, useCallback, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { fmtMoney } from "../lib/format.jsx";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { currentWeekSaturdayCT, addDaysISO } from "../lib/weeks.js";

// ─── Payroll ──────────────────────────────────────────────────
// The old Payroll Process manual page, moved into the Team module (Peter
// 2026-09-14). The written steps stay written; step 3 is live, editable, and
// covers every active teammate instead of the two who happened to be typed into
// the page. Life stipends write back to team.weekly_life_benefit_agency_paid,
// which is the column the CPR benefits row and the comp pool already read.
//
// Steps 1, 2 and 4 read one function, team_payroll_week, for whichever week is
// picked at the top (Sunday to Saturday, Central): hours for anyone paid by the
// hour, every paid day off in the week, and the bonuses due off that week's CPR.
// The picked week lives in the URL as pweek, so a refresh or a new tab lands on
// the same week. Worked hours
// come from get_weekly_cpr_hours, the same function the CPR itself reads, so
// the payroll tab and the CPR can never show different numbers.

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

const CARD = { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: "14px 16px", marginBottom: 14 };
const STEP_H = { fontSize: 13, fontWeight: 700, color: T.slate900, margin: "0 0 8px 0" };
const LI = { fontSize: 13, color: T.slate700, lineHeight: 1.6, margin: "0 0 4px 0" };
const UL = { fontSize: 13, color: T.slate700, lineHeight: 1.6, margin: "0 0 4px 0", paddingLeft: 20 };
const BULLET = { margin: "0 0 4px 0" };
const INPUT = { padding: "6px 8px", fontSize: 12, border: `1px solid ${T.slate200}`, borderRadius: 6, width: "100%" };
const BTN = { padding: "6px 12px", fontSize: 12, fontWeight: 600, borderRadius: 7, border: "none", cursor: "pointer" };
const ARROW = { ...BTN, background: T.slate100, color: T.slate700, padding: "7px 12px", fontSize: 14, lineHeight: 1 };
const ARROW_OFF = { ...ARROW, color: T.slate200, cursor: "default" };
const SELECT = { ...INPUT, width: "auto", maxWidth: "100%" };
const TABLE_WRAP = { overflowX: "auto", WebkitOverflowScrolling: "touch", marginTop: 8 };
const TH = { fontSize: 11, fontWeight: 700, color: T.slate500, textAlign: "left", padding: "6px 10px 6px 0", whiteSpace: "nowrap" };
const TD = { fontSize: 13, color: T.slate700, padding: "6px 10px 6px 0", whiteSpace: "nowrap", boxSizing: "border-box" };
const MUTED = { fontSize: 12, color: T.slate500 };

function money(n) {
  return fmtMoney(n, { decimals: 2 });
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
// The week comes from lib/weeks.js, so the browser's own clock and time zone
// never decide which week is this week.
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

function PersonBenefits({ person, onChanged }) {
  const [editing, setEditing] = useState(null); // line id, or "new"
  const lines = Array.isArray(person?.lines) ? person.lines : [];

  const remove = async (id) => {
    const { error: e } = await supabase.rpc("team_payroll_line_delete", { p_id: id });
    if (!e) onChanged();
  };

  return (
    <div style={{ borderTop: `1px solid ${T.slate200}`, padding: "10px 0" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: T.slate900 }}>{person?.name}</div>
        <button style={{ ...BTN, background: T.slate100, color: T.slate700 }} onClick={() => setEditing(editing === "new" ? null : "new")}>
          {editing === "new" ? "Close" : "Add a line"}
        </button>
      </div>
      {!lines.length && editing !== "new" && (
        <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>No benefits or deductions on file.</div>
      )}
      {lines.map((l) => (
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
            <LineEditor personId={person.team_member_id} line={l} onCancel={() => setEditing(null)} onDone={() => { setEditing(null); onChanged(); }} />
          )}
        </div>
      ))}
      {editing === "new" && (
        <LineEditor personId={person.team_member_id} line={null} onCancel={() => setEditing(null)} onDone={() => { setEditing(null); onChanged(); }} />
      )}
    </div>
  );
}

// Hours for the week, one row per person paid by the hour.
function HoursTable({ rows }) {
  if (!rows.length) return <div style={MUTED}>Nobody is paid by the hour right now.</div>;
  return (
    <div style={TABLE_WRAP}>
      <table style={{ borderCollapse: "collapse", width: "100%" }}>
        <thead>
          <tr>
            <th style={TH}>Who</th>
            {DAYS.map((d) => <th key={d.id} style={{ ...TH, textAlign: "right" }}>{d.label}</th>)}
            <th style={{ ...TH, textAlign: "right" }}>Worked</th>
            <th style={{ ...TH, textAlign: "right" }}>Paid time off</th>
            <th style={{ ...TH, textAlign: "right" }}>Over 40</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((p) => {
            const byDay = {};
            (p.days || []).forEach((d) => { byDay[d.day_label] = d; });
            return (
              <tr key={p.team_member_id} style={{ borderTop: `1px solid ${T.slate200}` }}>
                <td style={{ ...TD, fontWeight: 600, color: T.slate900 }}>{p.name}</td>
                {DAYS.map((d) => (
                  <td key={d.id} style={{ ...TD, textAlign: "right" }}>{hrs(byDay[d.id]?.hours)}</td>
                ))}
                <td style={{ ...TD, textAlign: "right", fontWeight: 700, color: T.slate900 }}>{hrs(p.worked_hours)}</td>
                <td style={{ ...TD, textAlign: "right" }}>{hrs(p.paid_time_off_hours)}</td>
                <td style={{ ...TD, textAlign: "right", color: Number(p.overtime_hours) > 0 ? T.amber : T.slate500 }}>
                  {hrs(p.overtime_hours)}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

// Every paid day off that lands in the week, one line each.
function TimeOffList({ rows }) {
  if (!rows.length) return <div style={MUTED}>No paid time off this week.</div>;
  return (
    <ul style={UL}>
      {rows.map((r, i) => (
        <li key={`${r.team_member_id}-${r.work_date}-${i}`} style={BULLET}>
          <strong>{r.name}</strong> · {dayLabel(r.work_date)} · {r.label} · {hrs(r.hours)} hours
        </li>
      ))}
    </ul>
  );
}

// Bonuses due for the week, straight off the CPR.
function BonusTable({ rows, hasReport }) {
  if (!hasReport) return <div style={MUTED}>No CPR for this week yet.</div>;
  const paying = rows.filter((r) => Array.isArray(r.lines) && r.lines.length);
  if (!paying.length) return <div style={MUTED}>No bonuses due on this week's CPR yet.</div>;
  return (
    <div style={TABLE_WRAP}>
      <table style={{ borderCollapse: "collapse", width: "100%" }}>
        <thead>
          <tr>
            <th style={TH}>Who</th>
            <th style={TH}>Code</th>
            <th style={TH}>Bonus</th>
            <th style={{ ...TH, textAlign: "right" }}>Amount</th>
          </tr>
        </thead>
        <tbody>
          {paying.map((p) => (
            (p.lines || []).map((l, i) => (
              <tr key={`${p.team_member_id}-${l.label}`} style={i === 0 ? { borderTop: `1px solid ${T.slate200}` } : undefined}>
                <td style={{ ...TD, fontWeight: i === 0 ? 600 : 400, color: i === 0 ? T.slate900 : T.slate500 }}>
                  {i === 0 ? p.name : ""}
                </td>
                <td style={{ ...TD, fontFamily: "ui-monospace, monospace" }}>{l.code || "—"}</td>
                <td style={TD}>{l.label}</td>
                <td style={{ ...TD, textAlign: "right", fontWeight: 600, color: T.slate900 }}>{money(l.amount)}</td>
              </tr>
            ))
          ))}
          <tr style={{ borderTop: `1px solid ${T.slate200}` }}>
            <td style={{ ...TD, fontWeight: 700, color: T.slate900 }} colSpan={3}>Total due</td>
            <td style={{ ...TD, textAlign: "right", fontWeight: 700, color: T.slate900 }}>
              {money(paying.reduce((sum, p) => sum + (Number(p.total) || 0), 0))}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  );
}

export default function TeamPayroll() {
  const weeks = useMemo(() => buildWeekOptions(), []);
  const weekIds = useMemo(() => weeks.map((w) => w.id), [weeks]);
  const [pickedWeek, setPickedWeek, hrefForWeek] = useTabParam("pweek", weeks[0].id, weekIds);
  const [people, setPeople] = useState(undefined); // undefined = loading
  const [week, setWeek] = useState(undefined);     // undefined = loading
  const [error, setError] = useState(null);
  const [weekError, setWeekError] = useState(null);

  const load = useCallback(async () => {
    const { data, error: e } = await supabase.rpc("team_payroll_lines_list");
    if (e) { setError(e.message); setPeople(null); return; }
    setError(null);
    setPeople(Array.isArray(data) ? data : []);
  }, []);

  const loadWeek = useCallback(async () => {
    setWeek(undefined);
    const { data, error: e } = await supabase.rpc("team_payroll_week", {
      p_agency_id: AGENCY_ID,
      p_week_ending_date: pickedWeek,
    });
    if (e) { setWeekError(e.message); setWeek(null); return; }
    setWeekError(null);
    setWeek(data || null);
  }, [pickedWeek]);

  useEffect(() => { load(); }, [load]);
  useEffect(() => { loadWeek(); }, [loadWeek]);

  const hoursRows = Array.isArray(week?.hours) ? week.hours : [];
  const timeOffRows = Array.isArray(week?.time_off) ? week.time_off : [];
  const bonusRows = Array.isArray(week?.bonuses) ? week.bonuses : [];
  const weekText = week ? weekLabel(week.week_start_date, week.week_ending_date) : "";
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
      {weekText && (
        <div style={{ ...MUTED, marginBottom: 10 }}>
          Hours, paid time off and bonuses below are for {weekText}.
        </div>
      )}
      {weekError && <div style={{ color: T.red, fontSize: 12, fontWeight: 600, marginBottom: 10 }}>{weekError}</div>}

      <div style={CARD}>
        <div style={STEP_H}>Step 1 · Hours</div>
        <div style={LI}>Work out the hours for the week for anyone who is not salaried.</div>
        {week === undefined ? <div style={MUTED}>Loading the hours…</div> : <HoursTable rows={hoursRows} />}
      </div>

      <div style={CARD}>
        <div style={STEP_H}>Step 2 · Time off</div>
        <ul style={UL}>
          <li style={BULLET}>Time off is booked in the Time Off module, and it comes in two sizes only: a half day is 4 hours, a full day is 8.</li>
          <li style={BULLET}>When the office is closed, that is a day off for everyone unless it has been changed by hand. A closed office replaces any other time off that day, including a day off earned by winning the week.</li>
          <li style={BULLET}>Paid time off shows in the weekly hours total on the CPR under PTO. It never counts toward the 40-hour overtime line.</li>
          <li style={BULLET}>Unpaid time off is not recorded anywhere. Those hours simply do not appear.</li>
          <li style={BULLET}>Someone's last week is paid by hours worked out of 40, not by whole days.</li>
        </ul>
        <div style={{ ...STEP_H, marginTop: 12 }}>Paid time off this week</div>
        {week === undefined ? <div style={MUTED}>Loading the time off…</div> : <TimeOffList rows={timeOffRows} />}
      </div>

      <div style={CARD}>
        <div style={STEP_H}>Step 3 · Benefits and deductions</div>
        <div style={{ ...LI, marginBottom: 10 }}>
          Life stipends are added as income from the dropdown so the benefit is taxed. Medical, dental and vision come out automatically, so just check they are on the right-hand side. Everything below is live.
        </div>
        {error && <div style={{ color: T.red, fontSize: 12, fontWeight: 600 }}>{error}</div>}
        {people === undefined && <div style={MUTED}>Loading the team…</div>}
        {Array.isArray(people) && !people.length && <div style={MUTED}>No active team members.</div>}
        {(people || []).map((p) => (
          <PersonBenefits key={p.team_member_id} person={p} onChanged={load} />
        ))}
      </div>

      <div style={CARD}>
        <div style={STEP_H}>Step 4 · Bonuses</div>
        <div style={LI}><strong>Leslie:</strong> paid the first Friday of the month, on the first check date.</div>
        <ul style={UL}>
          <li style={BULLET}>5Goals — Goals/Profit (Leslie's Goals)</li>
          <li style={BULLET}>$600 a month in kids' goals bonuses: $300 for Goose if goals are hit, $300 for Duck if goals are hit.</li>
        </ul>
        <div style={{ ...LI, marginTop: 10 }}>The agent sends the weekly CPR report with the bonuses due, on the sales tab. The codes are:</div>
        <ul style={UL}>
          <li style={BULLET}>0Advnce — Advance</li>
          <li style={BULLET}>1Health — Health</li>
          <li style={BULLET}>2Serve — Service Surge</li>
          <li style={BULLET}>3True — True Pay</li>
          <li style={BULLET}>4Manage — Manager</li>
          <li style={BULLET}>5Goals — Goals/Profit (Agency Profit)</li>
        </ul>
        <div style={{ ...LI, marginTop: 10 }}>Christmas bonus: OT Scorecard × (1 + (Weeks / 100)) × full or part time status.</div>

        <div style={{ ...STEP_H, marginTop: 12 }}>Bonuses due this week</div>
        {week === undefined
          ? <div style={MUTED}>Loading the bonuses…</div>
          : <BonusTable rows={bonusRows} hasReport={!!week?.has_cpr_report} />}
      </div>

      <div style={CARD}>
        <div style={STEP_H}>Step 5 · Reimbursements</div>
        <ul style={UL}>
          <li style={BULLET}><strong>Going out:</strong> do we owe anyone for lunches or anything else?</li>
          <li style={BULLET}><strong>Coming in:</strong> does anyone owe us from an advance? If so, take it now as a miscellaneous deduction.</li>
          <li style={BULLET}><strong>Fitbit:</strong> take $25 a week until it is paid off, regardless of bonus, as a deduction. The only exception is if we need to exchange it. Send the agent and the team member a record of the deduction and the remaining balance.</li>
        </ul>
      </div>
    </div>
  );
}
