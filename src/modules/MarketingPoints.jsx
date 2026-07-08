// ============================================================
// MarketingPoints.jsx — Admin surface for weekly marketing point entry
//
// Purpose:
//   Peter enters weekly per-member marketing points. Points = the DOLLAR
//   value of cash marketing spiffs paid to each person that week
//   (e.g. Cassie earned $22.35 in review spiffs → 22.35 points).
//   Retroactive kickers naturally roll in via the dollar total.
//   Data feeds public.marketing_points, which feeds
//   compute_weekly_marketing_bonus → weekly_cpr_team_detail.
//
// Backend:
//   Table:    public.marketing_points (UNIQUE agency+member+week)
//   RPC:      public.compute_weekly_marketing_bonus(agency_id, week_end_date)
//   Rule:     Marketing Bonus Pool — 10% envelope, 50% underspend to team
//             (locked 2026-07-07)
//
// Point rule:
//   points = $ value of cash marketing spiff for that person that week
//   - Review: $15 base + $0.15 retro per prior review (up to 99×)
//   - Referral quoted: $30 flat
//   - Referral sold: $30 base + $0.30 retro per prior sold (up to 99×)
// ============================================================
import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { T } from "../lib/theme.js";
import { fmt, safeNum } from "../lib/utils.js";

function nextSaturdayISO(from = new Date()) {
  const d = new Date(from);
  const dow = d.getDay();
  const add = (6 - dow + 7) % 7;
  d.setDate(d.getDate() + add);
  return d.toISOString().slice(0, 10);
}

function shiftSaturday(iso, weeks) {
  const d = new Date(iso + "T00:00:00");
  d.setDate(d.getDate() + weeks * 7);
  return d.toISOString().slice(0, 10);
}

export default function MarketingPoints() {
  const vp = useViewport();
  const [weekEnd, setWeekEnd] = useState(nextSaturdayISO());
  const [team, setTeam] = useState([]);
  const [inputs, setInputs] = useState({});
  const [pool, setPool] = useState(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [savedMsg, setSavedMsg] = useState("");
  const [err, setErr] = useState(null);

  useEffect(() => {
    if (!supabase || !AGENCY_ID) return;
    let cancelled = false;
    async function load() {
      setLoading(true);
      setErr(null);
      try {
        const { data: teamRows, error: teamErr } = await supabase
          .from("team")
          .select("id, first_name, last_name, nickname, hire_date, role_level, category, is_admin_backoffice, is_active, archived_at, is_test_user")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true)
          .eq("category", "agency")
          .order("hire_date", { ascending: true });
        if (teamErr) throw teamErr;

        const eligible = (teamRows || []).filter(
          t =>
            !t.is_admin_backoffice &&
            !t.archived_at &&
            !t.is_test_user &&
            (t.role_level || "") !== "Owner"
        );
        if (cancelled) return;
        setTeam(eligible);

        const { data: existRows, error: existErr } = await supabase
          .from("marketing_points")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .eq("week_end_date", weekEnd);
        if (existErr) throw existErr;

        const inputInit = {};
        for (const t of eligible) {
          const row = (existRows || []).find(r => r.team_member_id === t.id);
          inputInit[t.id] = {
            points: row ? String(row.points ?? 0) : "0",
            notes:  row ? (row.notes ?? "") : "",
          };
        }
        if (cancelled) return;
        setInputs(inputInit);

        const { data: poolData, error: poolErr } = await supabase.rpc(
          "compute_weekly_marketing_bonus",
          { p_agency_id: AGENCY_ID, p_week_end_date: weekEnd }
        );
        if (poolErr) throw poolErr;
        if (!cancelled) setPool(poolData);
      } catch (e) {
        if (!cancelled) setErr(e.message || String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => { cancelled = true; };
  }, [weekEnd]);

  const updateInput = (memberId, field, value) => {
    setInputs(prev => ({
      ...prev,
      [memberId]: { ...prev[memberId], [field]: value },
    }));
    setSavedMsg("");
  };

  const weekTotalPoints = useMemo(
    () => team.reduce((sum, m) => sum + safeNum(inputs[m.id]?.points), 0),
    [team, inputs]
  );

  async function saveAll() {
    if (!supabase) return;
    setSaving(true);
    setSavedMsg("");
    setErr(null);
    try {
      const rows = team.map(m => {
        const i = inputs[m.id] || {};
        return {
          agency_id: AGENCY_ID,
          team_member_id: m.id,
          week_end_date: weekEnd,
          points: safeNum(i.points),
          notes: (i.notes || "").trim() || null,
          source: "peter_weekly_input",
          updated_at: new Date().toISOString(),
        };
      });
      const { error: upErr } = await supabase
        .from("marketing_points")
        .upsert(rows, { onConflict: "agency_id,team_member_id,week_end_date" });
      if (upErr) throw upErr;

      const { error: writeErr } = await supabase.rpc(
        "write_weekly_marketing_bonus",
        { p_agency_id: AGENCY_ID, p_week_end_date: weekEnd }
      );
      if (writeErr && !/no weekly_cpr_reports/i.test(writeErr.message || "")) {
        throw writeErr;
      }
      const { data: poolData } = await supabase.rpc(
        "compute_weekly_marketing_bonus",
        { p_agency_id: AGENCY_ID, p_week_end_date: weekEnd }
      );
      setPool(poolData);
      setSavedMsg("Saved.");
      setTimeout(() => setSavedMsg(""), 3000);
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setSaving(false);
    }
  }

  const css = {
    page: { maxWidth: 900, margin: "0 auto", color: T.slate900 },
    h1: { fontSize: vp.isPhone ? 20 : 24, fontWeight: 800, color: T.slate900, marginBottom: 4 },
    sub: { fontSize: 13, color: T.slate500, marginBottom: 18, lineHeight: 1.5 },
    card: { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: vp.isPhone ? 12 : 16, marginBottom: 14 },
    weekPickerRow: { display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap", marginBottom: 12 },
    weekBtn: { background: T.white, border: `1px solid ${T.slate300}`, borderRadius: 6, padding: "6px 10px", fontSize: 12, color: T.slate700, cursor: "pointer" },
    weekInput: { border: `1px solid ${T.slate300}`, borderRadius: 6, padding: "6px 10px", fontSize: 14, fontWeight: 600, color: T.slate900, background: T.white },
    poolGrid: { display: "grid", gridTemplateColumns: vp.isPhone ? "1fr 1fr" : "repeat(4, 1fr)", gap: 10, marginTop: 8 },
    metric: { background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 8, padding: 10 },
    metricLabel: { fontSize: 10, color: T.slate500, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700 },
    metricValue: { fontSize: 18, fontWeight: 800, color: T.slate900, marginTop: 2 },
    memberRow: { display: "grid", gridTemplateColumns: vp.isPhone ? "1fr" : "1fr 140px 120px", gap: 12, padding: "10px 0", borderBottom: `1px solid ${T.slate100}`, alignItems: vp.isPhone ? "stretch" : "center" },
    memberName: { fontWeight: 700, fontSize: 14, color: T.slate900 },
    input: { border: `1px solid ${T.slate300}`, borderRadius: 6, padding: "8px 10px", fontSize: 14, color: T.slate900, background: T.white, width: "100%", boxSizing: "border-box" },
    inputLabel: { fontSize: 10, color: T.slate500, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700, marginBottom: 4 },
    saveBtn: { background: T.blue, color: T.white, border: "none", borderRadius: 8, padding: "12px 20px", fontSize: 14, fontWeight: 700, cursor: "pointer", width: vp.isPhone ? "100%" : "auto", opacity: saving ? 0.6 : 1 },
    err: { color: T.red, fontSize: 12, marginTop: 8, padding: 8, background: T.redLt, borderRadius: 6 },
    ok: { color: T.green, fontSize: 12, fontWeight: 700, marginTop: 8 },
    ytdBadge: { fontSize: 13, fontWeight: 700, color: T.slate900, textAlign: vp.isPhone ? "left" : "right" },
    ytdSub: { fontSize: 10, fontWeight: 400, color: T.slate500 },
  };

  const envAnnual = pool?.envelope?.annual;
  const envYtd    = pool?.envelope?.ytd_target;
  const spendYtd  = pool?.spend?.ytd;
  const poolYtd   = pool?.pool?.pool_ytd;
  const totalPts  = pool?.pool?.total_points_ytd;

  return (
    <div style={css.page}>
      <div style={css.h1}>Marketing Points</div>
      <div style={css.sub}>
        Weekly per-member marketing points. <strong>1 point = $1 of marketing spiff paid.</strong> Retroactive
        kickers ($0.15/review, $0.30/sold referral) roll in automatically via the dollar total.
        Feeds the Marketing Bonus Pool (10% envelope, 50% underspend to team).
      </div>

      <div style={css.card}>
        <div style={css.weekPickerRow}>
          <button style={css.weekBtn} onClick={() => setWeekEnd(shiftSaturday(weekEnd, -1))}>← Prior wk</button>
          <input
            style={css.weekInput}
            type="date"
            value={weekEnd}
            onChange={e => setWeekEnd(e.target.value)}
          />
          <button style={css.weekBtn} onClick={() => setWeekEnd(shiftSaturday(weekEnd, +1))}>Next wk →</button>
          <button style={css.weekBtn} onClick={() => setWeekEnd(nextSaturdayISO())}>This wk</button>
        </div>

        {pool && (
          <div style={css.poolGrid}>
            <div style={css.metric}>
              <div style={css.metricLabel}>Envelope / yr</div>
              <div style={css.metricValue}>{fmt(envAnnual)}</div>
            </div>
            <div style={css.metric}>
              <div style={css.metricLabel}>YTD target</div>
              <div style={css.metricValue}>{fmt(envYtd)}</div>
            </div>
            <div style={css.metric}>
              <div style={css.metricLabel}>YTD spent</div>
              <div style={css.metricValue}>{fmt(spendYtd)}</div>
            </div>
            <div style={{ ...css.metric, background: safeNum(poolYtd) > 0 ? T.greenLt : T.redLt }}>
              <div style={css.metricLabel}>Pool YTD</div>
              <div style={{ ...css.metricValue, color: safeNum(poolYtd) > 0 ? T.green : T.red }}>{fmt(poolYtd)}</div>
            </div>
          </div>
        )}
      </div>

      <div style={css.card}>
        <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, marginBottom: 8 }}>
          Points this week &nbsp;
          <span style={{ fontWeight: 400, color: T.slate500 }}>
            (team total: <strong>{fmt(weekTotalPoints)}</strong>)
          </span>
        </div>

        {loading && <div style={{ color: T.slate500, fontSize: 12 }}>Loading…</div>}

        {!loading && team.length === 0 && (
          <div style={{ color: T.slate500, fontSize: 12, fontStyle: "italic" }}>No eligible team members found.</div>
        )}

        {!loading && team.map(m => {
          const name = m.nickname || m.first_name;
          const person = (pool?.people || []).find(p => p.team_member_id === m.id);
          return (
            <div key={m.id} style={css.memberRow}>
              <div style={css.memberName}>{name}</div>
              <div>
                <div style={css.inputLabel}>Points this week ($)</div>
                <input
                  style={css.input}
                  type="number"
                  min="0"
                  step="0.01"
                  value={inputs[m.id]?.points ?? "0"}
                  onChange={e => updateInput(m.id, "points", e.target.value)}
                />
              </div>
              <div style={css.ytdBadge}>
                {fmt(person?.earned_ytd ?? 0)}
                <div style={css.ytdSub}>
                  {safeNum(person?.points_ytd).toFixed(2)} pts YTD ({safeNum(person?.share_pct).toFixed(1)}%)
                </div>
              </div>
            </div>
          );
        })}

        {!loading && team.length > 0 && (
          <details style={{ marginTop: 12 }}>
            <summary style={{ cursor: "pointer", fontSize: 12, color: T.slate500, fontWeight: 600 }}>
              Add per-member notes (optional)
            </summary>
            <div style={{ marginTop: 8, display: "flex", flexDirection: "column", gap: 8 }}>
              {team.map(m => (
                <div key={m.id + "-notes"}>
                  <div style={css.inputLabel}>{m.nickname || m.first_name} — notes</div>
                  <input
                    style={css.input}
                    type="text"
                    value={inputs[m.id]?.notes ?? ""}
                    onChange={e => updateInput(m.id, "notes", e.target.value)}
                    placeholder="Breakdown (reviews, quoted, sold) or anything to remember"
                  />
                </div>
              ))}
            </div>
          </details>
        )}

        {err && <div style={css.err}>{err}</div>}
        {savedMsg && <div style={css.ok}>{savedMsg}</div>}

        <div style={{ marginTop: 14 }}>
          <button style={css.saveBtn} onClick={saveAll} disabled={saving || loading}>
            {saving ? "Saving…" : "Save week"}
          </button>
        </div>
      </div>

      {pool?.people && pool.people.length > 0 && (
        <div style={css.card}>
          <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, marginBottom: 8 }}>
            YTD leaderboard &nbsp;
            <span style={{ fontWeight: 400, color: T.slate500 }}>
              ({safeNum(totalPts).toFixed(2)} pts total)
            </span>
          </div>
          {pool.people.map(p => {
            const name = (team.find(t => t.id === p.team_member_id)?.nickname) || p.name;
            const share = safeNum(p.share_pct);
            return (
              <div key={p.team_member_id} style={{
                display: "grid",
                gridTemplateColumns: "1fr auto auto",
                gap: 12,
                padding: "8px 0",
                borderBottom: `1px solid ${T.slate100}`,
                alignItems: "center",
              }}>
                <div style={{ fontWeight: 600, fontSize: 14, color: T.slate900 }}>{name}</div>
                <div style={{ fontSize: 12, color: T.slate500 }}>
                  {safeNum(p.points_ytd).toFixed(2)} pts &middot; {share.toFixed(1)}%
                </div>
                <div style={{ fontWeight: 700, fontSize: 14, color: T.slate900 }}>{fmt(p.earned_ytd)}</div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
