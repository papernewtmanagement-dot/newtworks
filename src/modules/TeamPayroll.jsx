import { useState, useEffect, useCallback } from "react";
import { supabase } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

// ─── Payroll ──────────────────────────────────────────────────
// The old Payroll Process manual page, moved into the Team module (Peter
// 2026-09-14). The written steps stay written; step 3 is live, editable, and
// covers every active teammate instead of the two who happened to be typed into
// the page. Life stipends write back to team.weekly_life_benefit_agency_paid,
// which is the column the CPR benefits row and the comp pool already read.

const LINE_TYPES = [
  { id: "life_stipend",    label: "Life stipend (income, not a deduction)" },
  { id: "medical",         label: "Medical deduction" },
  { id: "dental",          label: "Dental deduction" },
  { id: "vision",          label: "Vision deduction" },
  { id: "other_deduction", label: "Other deduction" },
];

const CARD = { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: "14px 16px", marginBottom: 14 };
const STEP_H = { fontSize: 13, fontWeight: 700, color: T.slate900, margin: "0 0 8px 0" };
const LI = { fontSize: 13, color: T.slate700, lineHeight: 1.6, margin: "0 0 4px 0" };
const INPUT = { padding: "6px 8px", fontSize: 12, border: `1px solid ${T.slate200}`, borderRadius: 6, width: "100%" };
const BTN = { padding: "6px 12px", fontSize: 12, fontWeight: 600, borderRadius: 7, border: "none", cursor: "pointer" };

function money(n) {
  const v = Number(n);
  return Number.isFinite(v) ? `$${v.toFixed(2)}` : "—";
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

export default function TeamPayroll() {
  const [people, setPeople] = useState(undefined); // undefined = loading
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    const { data, error: e } = await supabase.rpc("team_payroll_lines_list");
    if (e) { setError(e.message); setPeople(null); return; }
    setError(null);
    setPeople(Array.isArray(data) ? data : []);
  }, []);

  useEffect(() => { load(); }, [load]);

  return (
    <div>
      <div style={CARD}>
        <div style={STEP_H}>Step 1 · Hours</div>
        <div style={LI}>Work out the hours for the week for anyone who is not salaried.</div>
      </div>

      <div style={CARD}>
        <div style={STEP_H}>Step 2 · Time off</div>
        <div style={LI}>Time off is booked in the Time Off module, and it comes in two sizes only: a half day is 4 hours, a full day is 8.</div>
        <div style={LI}>When the office is closed, that is a day off for everyone unless it has been changed by hand. A closed office replaces any other time off that day, including a day off earned by winning the week.</div>
        <div style={LI}>Paid time off shows in the weekly hours total on the CPR under PTO. It never counts toward the 40-hour overtime line.</div>
        <div style={LI}>Unpaid time off is not recorded anywhere. Those hours simply do not appear.</div>
        <div style={LI}>Someone's last week is paid by hours worked out of 40, not by whole days.</div>
      </div>

      <div style={CARD}>
        <div style={STEP_H}>Step 3 · Benefits and deductions</div>
        <div style={{ ...LI, marginBottom: 10 }}>
          Life stipends are added as income from the dropdown so the benefit is taxed. Medical, dental and vision come out automatically, so just check they are on the right-hand side. Everything below is live.
        </div>
        {error && <div style={{ color: T.red, fontSize: 12, fontWeight: 600 }}>{error}</div>}
        {people === undefined && <div style={{ fontSize: 12, color: T.slate500 }}>Loading the team…</div>}
        {Array.isArray(people) && !people.length && <div style={{ fontSize: 12, color: T.slate500 }}>No active team members.</div>}
        {(people || []).map((p) => (
          <PersonBenefits key={p.team_member_id} person={p} onChanged={load} />
        ))}
      </div>

      <div style={CARD}>
        <div style={STEP_H}>Step 4 · Bonuses</div>
        <div style={LI}><strong>Leslie:</strong> paid the first Friday of the month, on the first check date.</div>
        <div style={LI}>5Goals — Goals/Profit (Leslie's Goals)</div>
        <div style={LI}>$600 a month in kids' goals bonuses: $300 for Goose if goals are hit, $300 for Duck if goals are hit.</div>
        <div style={{ ...LI, marginTop: 8 }}>The agent sends the weekly CPR report with the bonuses due, on the sales tab. The codes are:</div>
        <div style={LI}>0Advnce — Advance</div>
        <div style={LI}>1Health — Health</div>
        <div style={LI}>2Serve — Service Surge</div>
        <div style={LI}>3True — True Pay</div>
        <div style={LI}>4Manage — Manager</div>
        <div style={LI}>5Goals — Goals/Profit (Agency Profit)</div>
        <div style={{ ...LI, marginTop: 8 }}>Christmas bonus: OT Scorecard × (1 + (Weeks / 100)) × full or part time status.</div>
      </div>

      <div style={CARD}>
        <div style={STEP_H}>Step 5 · Reimbursements</div>
        <div style={LI}><strong>Going out:</strong> do we owe anyone for lunches or anything else?</div>
        <div style={LI}><strong>Coming in:</strong> does anyone owe us from an advance? If so, take it now as a miscellaneous deduction.</div>
        <div style={LI}><strong>Fitbit:</strong> take $25 a week until it is paid off, regardless of bonus, as a deduction. The only exception is if we need to exchange it. Send the agent and the team member a record of the deduction and the remaining balance.</div>
      </div>
    </div>
  );
}
