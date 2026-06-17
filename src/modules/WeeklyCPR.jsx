import { useState, useEffect, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";

// ── Design tokens (mirrors Dashboard.jsx) ──────────────────────
import { T } from "../lib/theme.js";

// ── Date helpers ───────────────────────────────────────────────
// Week ends Saturday. Default: the upcoming (or current) Saturday.
// Sun→+6, Mon→+5, ..., Fri→+1, Sat→0
function upcomingSaturdayISO(d = new Date()) {
  const dow = d.getDay(); // 0=Sun … 6=Sat
  const offset = (6 - dow + 7) % 7;
  const target = new Date(d);
  target.setDate(d.getDate() + offset);
  return target.toISOString().slice(0, 10);
}

function prevSaturdayISO(satISO) {
  const d = new Date(satISO + "T00:00:00");
  d.setDate(d.getDate() - 7);
  return d.toISOString().slice(0, 10);
}

function fmtDateLong(iso) {
  if (!iso) return "—";
  try {
    return new Date(iso + "T00:00:00").toLocaleDateString("en-US", {
      weekday: "long", month: "long", day: "numeric", year: "numeric",
    });
  } catch { return iso; }
}

function fmtTime(ts) {
  if (!ts) return "—";
  try {
    return new Date(ts).toLocaleString("en-US", {
      month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
    });
  } catch { return ts; }
}

// ── Reusable bits ──────────────────────────────────────────────
const Card = ({ children, style = {} }) => (
  <div style={{
    background: T.white, borderRadius: 12, border: `1px solid ${T.slate200}`,
    padding: "16px 18px", ...style,
  }}>{children}</div>
);

const Label = ({ children, style = {} }) => (
  <div style={{
    fontSize: 10, fontWeight: 700, color: T.slate500,
    textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 6, ...style,
  }}>{children}</div>
);

const SectionHeader = ({ icon, title, hint }) => (
  <div style={{ marginBottom: 12 }}>
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <span style={{ fontSize: 18 }}>{icon}</span>
      <span style={{ fontSize: 15, fontWeight: 800, color: T.slate800 }}>{title}</span>
    </div>
    {hint ? (
      <div style={{ fontSize: 11, color: T.slate500, marginTop: 2, marginLeft: 26 }}>{hint}</div>
    ) : null}
  </div>
);

// Numeric cell input
const NumInput = ({ value, onChange, width = 70, allowNeg = true, step = 1 }) => (
  <input
    type="number"
    step={step}
    value={value ?? ""}
    onChange={(e) => {
      const v = e.target.value;
      if (v === "") return onChange(null);
      const n = Number(v);
      if (!allowNeg && n < 0) return;
      onChange(n);
    }}
    style={{
      width, padding: "6px 8px", border: `1px solid ${T.slate300}`,
      borderRadius: 6, fontSize: 13, textAlign: "right", fontVariantNumeric: "tabular-nums",
      background: T.white, color: T.slate900,
    }}
  />
);

const TextCell = ({ value, onChange, placeholder = "—" }) => (
  <input
    type="text"
    value={value ?? ""}
    onChange={(e) => onChange(e.target.value || null)}
    placeholder={placeholder}
    style={{
      width: "100%", padding: "6px 8px", border: `1px solid ${T.slate300}`,
      borderRadius: 6, fontSize: 12, color: T.slate900, background: T.white,
    }}
  />
);

// Done/Missed pill toggle (true = Done, false = Missed)
const DoneToggle = ({ value, onChange }) => {
  const done = value !== false;
  return (
    <button
      type="button"
      onClick={() => onChange(!done)}
      style={{
        padding: "4px 10px", borderRadius: 99, fontSize: 11, fontWeight: 700,
        cursor: "pointer", minWidth: 64,
        border: done ? `1px solid ${T.green}40` : `1px solid ${T.red}40`,
        background: done ? T.greenLt : T.redLt,
        color: done ? T.green : T.red,
      }}
    >{done ? "Done" : "Missed"}</button>
  );
};

const Th = ({ children, align = "left", w }) => (
  <th style={{
    padding: "8px 8px", fontSize: 10, fontWeight: 700, color: T.slate500,
    textTransform: "uppercase", letterSpacing: 0.4, textAlign: align,
    borderBottom: `1px solid ${T.slate200}`, whiteSpace: "nowrap",
    ...(w ? { width: w } : {}),
  }}>{children}</th>
);

const Td = ({ children, align = "left", style = {} }) => (
  <td style={{
    padding: "8px 8px", fontSize: 12, color: T.slate800,
    textAlign: align, borderBottom: `1px solid ${T.slate100}`, ...style,
  }}>{children}</td>
);

// ── Column definitions ─────────────────────────────────────────
const EOD_KEYS = [
  ["cpr_reply_done", "CPR Reply"],
  ["wrapup_done", "Wrapup"],
  ["inbox_done", "Inbox"],
];

const CHECKLIST_KEYS = [
  ["shareds_done", "Shareds"],
  ["texts_done", "Texts"],
  ["deposits_done", "Deposits"],
  ["appts_done", "Appts"],
  ["tasks_done", "Tasks"],
  ["cases_done", "Cases"],
  ["no_fu_task_done", "No FU Task"],
  ["new_opps_done", "New Opps"],
  ["no_onboarding_done", "No Onboarding"],
  ["no_phone_done", "No Phone"],
  ["bad_data_done", "Bad Data"],
];

function blankDetail(team_member_id) {
  const row = {
    team_member_id,
    carryover: 0, missed: 0, cost: 0, total: 0, paid: 0, owed: 0,
    code_reds: null, code_yellows: null,
  };
  EOD_KEYS.forEach(([k]) => { row[k] = true; });
  CHECKLIST_KEYS.forEach(([k]) => { row[k] = true; });
  return row;
}

// ── Main component ────────────────────────────────────────────
export default function WeeklyCPR({ onClose = () => {} }) {
  const [weekEnding, setWeekEnding] = useState(null);
  const [report, setReport] = useState(null);
  const [details, setDetails] = useState({});
  const [prevReport, setPrevReport] = useState(null);
  const [members, setMembers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [savedAt, setSavedAt] = useState(null);
  const [error, setError] = useState(null);

  // Determine the default week on mount: the most recent Saturday with no row yet.
  // Walks back up to 100 Saturdays from the current/upcoming one. If everything in
  // that window is saved (very unusual), falls forward to the next future Saturday.
  useEffect(() => {
    let cancelled = false;
    async function determineDefault() {
      if (!supabase) {
        if (!cancelled) setWeekEnding(upcomingSaturdayISO());
        return;
      }
      try {
        const { data: rows, error: err } = await supabase
          .from("weekly_cpr_reports")
          .select("week_ending_date")
          .eq("agency_id", AGENCY_ID)
          .order("week_ending_date", { ascending: false })
          .limit(100);
        if (cancelled) return;
        if (err) {
          setWeekEnding(upcomingSaturdayISO());
          return;
        }
        const saved = new Set((rows || []).map((r) => r.week_ending_date));
        const startSat = upcomingSaturdayISO();
        let candidate = startSat;
        for (let i = 0; i < 100; i++) {
          if (!saved.has(candidate)) {
            setWeekEnding(candidate);
            return;
          }
          const d = new Date(candidate + "T00:00:00");
          d.setDate(d.getDate() - 7);
          candidate = d.toISOString().slice(0, 10);
        }
        // Extremely unusual: 100 prior weeks all saved. Fall forward.
        const next = new Date(startSat + "T00:00:00");
        next.setDate(next.getDate() + 7);
        setWeekEnding(next.toISOString().slice(0, 10));
      } catch {
        if (!cancelled) setWeekEnding(upcomingSaturdayISO());
      }
    }
    determineDefault();
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    let cancelled = false;
    async function loadTeam() {
      if (!supabase) return;
      const { data, error: err } = await supabase
        .from("team")
        .select("id, first_name, last_name, nickname, role")
        .eq("agency_id", AGENCY_ID)
        .eq("is_active", true)
        .in("role", ["Inside Sales", "Acquisition", "Reception"])
        .order("role_level", { ascending: true })
        .order("last_name", { ascending: true });
      if (cancelled) return;
      if (err) { setError(err.message); return; }
      const order = ["Inside Sales", "Acquisition", "Reception"];
      const sorted = (data || []).slice().sort((a, b) => {
        const ai = order.indexOf(a.role);
        const bi = order.indexOf(b.role);
        if (ai !== bi) return ai - bi;
        return (a.last_name || "").localeCompare(b.last_name || "");
      });
      setMembers(sorted);
    }
    loadTeam();
    return () => { cancelled = true; };
  }, []);

  const loadWeek = useCallback(async (weekISO) => {
    if (!supabase) return;
    setLoading(true);
    setError(null);
    try {
      const prevISO = prevSaturdayISO(weekISO);
      const [thisRes, prevRes] = await Promise.all([
        supabase.from("weekly_cpr_reports").select("*")
          .eq("agency_id", AGENCY_ID).eq("week_ending_date", weekISO).maybeSingle(),
        supabase.from("weekly_cpr_reports")
          .select("auto_ratio_pct, auto_rank, auto_bonus, fire_ratio_pct, fire_rank, fire_bonus, week_ending_date")
          .eq("agency_id", AGENCY_ID).eq("week_ending_date", prevISO).maybeSingle(),
      ]);
      if (thisRes.error) throw thisRes.error;
      if (prevRes.error) throw prevRes.error;
      setPrevReport(prevRes.data || null);
      if (thisRes.data) {
        setReport(thisRes.data);
        setSavedAt(thisRes.data.updated_at);
        const { data: detRows, error: detErr } = await supabase
          .from("weekly_cpr_team_detail").select("*")
          .eq("weekly_cpr_report_id", thisRes.data.id);
        if (detErr) throw detErr;
        const byMember = {};
        (detRows || []).forEach((r) => { byMember[r.team_member_id] = r; });
        setDetails(byMember);
      } else {
        setReport({
          agency_id: AGENCY_ID, week_ending_date: weekISO,
          auto_ratio_pct: null, auto_rank: null, auto_bonus: null,
          fire_ratio_pct: null, fire_rank: null, fire_bonus: null,
          non_pays: 0, new_claims: 0, open_claims: 0, unreviewed_claims: 0,
          notes: null,
        });
        setDetails({});
        setSavedAt(null);
      }
    } catch (e) {
      setError(e.message || "Failed to load week");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { if (weekEnding) loadWeek(weekEnding); }, [weekEnding, loadWeek]);

  const updateReport = (patch) => setReport((r) => ({ ...(r || {}), ...patch }));
  const updateDetail = (memberId, patch) => {
    setDetails((d) => {
      const existing = d[memberId] || blankDetail(memberId);
      return { ...d, [memberId]: { ...existing, ...patch } };
    });
  };
  const getDetail = (memberId) => details[memberId] || blankDetail(memberId);

  async function handleSave() {
    if (!supabase) return;
    setSaving(true);
    setError(null);
    try {
      const reportPayload = { ...report, agency_id: AGENCY_ID, week_ending_date: weekEnding };
      const { id: _id, created_at: _ca, updated_at: _ua, ...rpClean } = reportPayload;
      const { data: upserted, error: upErr } = await supabase
        .from("weekly_cpr_reports")
        .upsert(rpClean, { onConflict: "agency_id,week_ending_date" })
        .select().single();
      if (upErr) throw upErr;

      const detailRows = members.map((m) => {
        const d = getDetail(m.id);
        return { ...d, agency_id: AGENCY_ID, weekly_cpr_report_id: upserted.id, team_member_id: m.id };
      }).map((r) => {
        const { id, created_at, updated_at, ...clean } = r;
        return clean;
      });

      if (detailRows.length > 0) {
        const { error: detErr } = await supabase
          .from("weekly_cpr_team_detail")
          .upsert(detailRows, { onConflict: "weekly_cpr_report_id,team_member_id" });
        if (detErr) throw detErr;
      }
      await loadWeek(weekEnding);
    } catch (e) {
      setError(e.message || "Save failed");
    } finally {
      setSaving(false);
    }
  }

  const memberLabel = (m) => {
    const display = m.nickname || m.first_name;
    return `${display} ${m.last_name?.[0] || ""}`.trim();
  };
  const fmtPct = (v) => (v === null || v === undefined || v === "") ? "—" : `${Number(v).toFixed(2)}%`;
  const fmtMoney = (v) => (v === null || v === undefined || v === "") ? "—" : `$${Number(v).toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;

  return (
    <div style={{
      position: "fixed", inset: 0, background: "rgba(15,23,42,0.55)",
      zIndex: 1000, overflow: "auto", padding: "24px 16px",
    }}>
      <div style={{
        maxWidth: 1240, margin: "0 auto", background: T.slate50,
        borderRadius: 14, border: `1px solid ${T.slate200}`,
        boxShadow: "0 10px 40px rgba(0,0,0,0.25)",
      }}>
        <div style={{
          display: "flex", justifyContent: "space-between", alignItems: "center",
          padding: "16px 22px", borderBottom: `1px solid ${T.slate200}`,
          background: T.white, borderRadius: "14px 14px 0 0",
        }}>
          <div>
            <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900 }}>
              📋 Weekly CPR — Compliance, Production, Retention
            </div>
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
              {weekEnding ? `Week ending ${fmtDateLong(weekEnding)}` : "Determining default week…"}
              {weekEnding ? (savedAt ? ` · last saved ${fmtTime(savedAt)}` : " · not yet saved") : ""}
            </div>
          </div>
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            <input type="date" value={weekEnding}
              onChange={(e) => setWeekEnding(e.target.value)}
              style={{ padding: "6px 10px", border: `1px solid ${T.slate300}`, borderRadius: 6, fontSize: 12, color: T.slate800 }}
            />
            <button onClick={handleSave} disabled={saving || loading || members.length === 0}
              style={{
                padding: "8px 16px", borderRadius: 8, fontSize: 12, fontWeight: 700,
                cursor: saving || loading ? "not-allowed" : "pointer",
                background: saving ? T.slate400 : T.blue, color: T.white,
                border: "none", opacity: saving || loading ? 0.7 : 1,
              }}>{saving ? "Saving…" : "Save Weekly CPR"}</button>
            <button onClick={onClose}
              style={{
                padding: "8px 14px", borderRadius: 8, fontSize: 12, fontWeight: 700,
                cursor: "pointer", background: T.white, color: T.slate700,
                border: `1px solid ${T.slate300}`,
              }}>Close</button>
          </div>
        </div>

        {error ? (
          <div style={{
            margin: "12px 22px 0", padding: "10px 14px", borderRadius: 8,
            background: T.redLt, color: T.red, fontSize: 12, fontWeight: 600,
            border: `1px solid ${T.red}40`,
          }}>⚠ {error}</div>
        ) : null}

        {loading || !weekEnding ? (
          <div style={{ padding: 60, textAlign: "center", color: T.slate500 }}>
            {weekEnding ? `Loading week ending ${fmtDateLong(weekEnding)}…` : "Finding the next CPR to enter…"}
          </div>
        ) : (
          <div style={{ padding: 22, display: "flex", flexDirection: "column", gap: 16 }}>

            <Card>
              <SectionHeader icon="📈" title="Retention ratios — this week"
                hint="Last week's values shown in grey for reference (read-only)." />
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
                {[
                  { key: "auto", label: "AUTO", color: T.blue },
                  { key: "fire", label: "FIRE", color: T.amber },
                ].map(({ key, label, color }) => {
                  const ratioK = `${key}_ratio_pct`;
                  const rankK = `${key}_rank`;
                  const bonusK = `${key}_bonus`;
                  return (
                    <div key={key} style={{
                      padding: 14, borderRadius: 10,
                      border: `1px solid ${color}30`, background: `${color}08`,
                    }}>
                      <div style={{ fontSize: 11, fontWeight: 800, color, letterSpacing: 0.6, marginBottom: 10 }}>{label}</div>
                      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 10 }}>
                        <div>
                          <Label>Ratio %</Label>
                          <NumInput value={report?.[ratioK]} onChange={(v) => updateReport({ [ratioK]: v })} width="100%" step="0.01" />
                          <div style={{ fontSize: 10, color: T.slate400, marginTop: 4 }}>Last wk: {fmtPct(prevReport?.[ratioK])}</div>
                        </div>
                        <div>
                          <Label>Rank</Label>
                          <NumInput value={report?.[rankK]} onChange={(v) => updateReport({ [rankK]: v })} width="100%" allowNeg={false} />
                          <div style={{ fontSize: 10, color: T.slate400, marginTop: 4 }}>Last wk: {prevReport?.[rankK] ?? "—"}</div>
                        </div>
                        <div>
                          <Label>Bonus</Label>
                          <NumInput value={report?.[bonusK]} onChange={(v) => updateReport({ [bonusK]: v })} width="100%" allowNeg={false} step="0.01" />
                          <div style={{ fontSize: 10, color: T.slate400, marginTop: 4 }}>Last wk: {fmtMoney(prevReport?.[bonusK])}</div>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            </Card>

            <Card>
              <SectionHeader icon="📂" title="Claims summary" />
              <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 12 }}>
                {[
                  ["non_pays", "Non Pays"],
                  ["new_claims", "New Claims"],
                  ["open_claims", "Open Claims"],
                  ["unreviewed_claims", "Unreviewed Claims"],
                ].map(([k, lbl]) => (
                  <div key={k}>
                    <Label>{lbl}</Label>
                    <NumInput value={report?.[k]} onChange={(v) => updateReport({ [k]: v })} width="100%" allowNeg={false} />
                  </div>
                ))}
              </div>
            </Card>

            <Card>
              <SectionHeader icon="✅" title="Required items — by team member"
                hint="From the top block of the spreadsheet (Carryover / Missed / Cost / Total / Paid / Owed)." />
              <div style={{ overflowX: "auto" }}>
                <table style={{ width: "100%", borderCollapse: "collapse" }}>
                  <thead>
                    <tr>
                      <Th w={140}>Team member</Th>
                      <Th align="right">Carryover</Th>
                      <Th align="right">Missed</Th>
                      <Th align="right">Cost</Th>
                      <Th align="right">Total</Th>
                      <Th align="right">Paid</Th>
                      <Th align="right">Owed</Th>
                    </tr>
                  </thead>
                  <tbody>
                    {members.map((m) => {
                      const d = getDetail(m.id);
                      return (
                        <tr key={m.id}>
                          <Td style={{ fontWeight: 700, color: T.slate800 }}>{memberLabel(m)}</Td>
                          {["carryover","missed","cost","total","paid","owed"].map((k) => (
                            <Td key={k} align="right">
                              <NumInput value={d[k]} onChange={(v) => updateDetail(m.id, { [k]: v ?? 0 })} />
                            </Td>
                          ))}
                        </tr>
                      );
                    })}
                    {members.length === 0 ? (
                      <tr><Td colSpan={7} style={{ color: T.slate400, textAlign: "center" }}>
                        No active team members found in roles: Inside Sales, Acquisition, Reception.
                      </Td></tr>
                    ) : null}
                  </tbody>
                </table>
              </div>
            </Card>

            <Card>
              <SectionHeader icon="🚦" title="Code Reds, Code Yellows & End-of-day items"
                hint="Reds/Yellows are free text — leave blank if none." />
              <div style={{ overflowX: "auto" }}>
                <table style={{ width: "100%", borderCollapse: "collapse" }}>
                  <thead>
                    <tr>
                      <Th w={140}>Team member</Th>
                      <Th>Code Reds</Th>
                      <Th>Code Yellows</Th>
                      <Th align="center" w={90}>CPR Reply</Th>
                      <Th align="center" w={90}>Wrapup</Th>
                      <Th align="center" w={90}>Inbox</Th>
                    </tr>
                  </thead>
                  <tbody>
                    {members.map((m) => {
                      const d = getDetail(m.id);
                      return (
                        <tr key={m.id}>
                          <Td style={{ fontWeight: 700, color: T.slate800 }}>{memberLabel(m)}</Td>
                          <Td><TextCell value={d.code_reds} onChange={(v) => updateDetail(m.id, { code_reds: v })} placeholder="—" /></Td>
                          <Td><TextCell value={d.code_yellows} onChange={(v) => updateDetail(m.id, { code_yellows: v })} placeholder="—" /></Td>
                          {EOD_KEYS.map(([k]) => (
                            <Td key={k} align="center">
                              <DoneToggle value={d[k]} onChange={(v) => updateDetail(m.id, { [k]: v })} />
                            </Td>
                          ))}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </Card>

            <Card>
              <SectionHeader icon="🗓️" title="Daily checklist — by team member"
                hint="Tap a pill to flip between Done and Missed. Defaults to Done." />
              <div style={{ overflowX: "auto" }}>
                <table style={{ width: "100%", borderCollapse: "collapse" }}>
                  <thead>
                    <tr>
                      <Th w={140}>Team member</Th>
                      {CHECKLIST_KEYS.map(([k, lbl]) => (
                        <Th key={k} align="center">{lbl}</Th>
                      ))}
                      <Th align="right" w={70}>Missed</Th>
                    </tr>
                  </thead>
                  <tbody>
                    {members.map((m) => {
                      const d = getDetail(m.id);
                      const missedCount = CHECKLIST_KEYS.reduce(
                        (acc, [k]) => acc + (d[k] === false ? 1 : 0), 0
                      );
                      return (
                        <tr key={m.id}>
                          <Td style={{ fontWeight: 700, color: T.slate800 }}>{memberLabel(m)}</Td>
                          {CHECKLIST_KEYS.map(([k]) => (
                            <Td key={k} align="center">
                              <DoneToggle value={d[k]} onChange={(v) => updateDetail(m.id, { [k]: v })} />
                            </Td>
                          ))}
                          <Td align="right" style={{
                            fontWeight: 800,
                            color: missedCount > 0 ? T.red : T.slate400,
                          }}>{missedCount}</Td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </Card>

            <Card>
              <SectionHeader icon="📝" title="Notes (optional)" />
              <textarea value={report?.notes ?? ""}
                onChange={(e) => updateReport({ notes: e.target.value || null })}
                placeholder="Anything else worth recording for this week…" rows={3}
                style={{
                  width: "100%", padding: "8px 10px", border: `1px solid ${T.slate300}`,
                  borderRadius: 6, fontSize: 13, color: T.slate900, background: T.white,
                  fontFamily: "inherit", resize: "vertical",
                }}
              />
            </Card>

            <div style={{
              display: "flex", justifyContent: "flex-end", gap: 8,
              padding: "8px 0", borderTop: `1px solid ${T.slate200}`,
            }}>
              <button onClick={handleSave} disabled={saving || loading || members.length === 0}
                style={{
                  padding: "10px 20px", borderRadius: 8, fontSize: 13, fontWeight: 700,
                  cursor: saving || loading ? "not-allowed" : "pointer",
                  background: saving ? T.slate400 : T.blue, color: T.white,
                  border: "none", opacity: saving || loading ? 0.7 : 1,
                }}>{saving ? "Saving…" : "Save Weekly CPR"}</button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
