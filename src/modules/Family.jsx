import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import InfoDot from "../components/InfoDot.jsx";
import { DayDoneStyles, Confetti, Dancer, CritterIcon } from "../components/Critters.jsx";

// =========================================================================
// Family.jsx — kids' chores, chore money, and the weekly close-out.
// All money rules live in the database, one function per job:
//   family_set_status()      records a chore outcome and its dollar effect
//   family_sweep_missed()    end of day: open chores are fined, stale extra picks go back
//   family_week_board()      the week grid for one kid
//   family_extras_available() extra chores anyone can pick on a day
//   family_week_register()   where the money started and each event of a week
//   family_close_week()      posts the week's chore pay and the 10% set-asides
//   family_balances()        spending / tithe / investments per kid
// This screen never works out a fine, a balance, a due date or a set-aside.
// The close-out adds and subtracts the numbers it is given; that is the lesson.
// Family login (role "family"): Done, Missed and extra chores only. Week, Money.
// Parents only: Carry, Excuse, any past day, the Chores and Fines tabs.
// =========================================================================

const PARENT_ROLES = ["owner", "manager"];
const TABS = ["week", "money", "fines", "setup"];
const TAB_LABELS = { week: "Week", money: "Money", fines: "Fines", setup: "Chores" };
const DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const DAY_FULL = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const PARTS = [["morning", "Morning"], ["afternoon", "Afternoon"], ["evening", "Evening"], ["anytime", "Any Time"]];
const DONE_STATES = ["claimed", "verified", "excused", "carried"];
const LEDGER_KINDS = [
  { kind: "payout",      bucket: "spend",  label: "Paid out cash",    sign: -1 },
  { kind: "tithe_given", bucket: "tithe",  label: "Gave tithe",       sign: -1 },
  { kind: "invested",    bucket: "invest", label: "Invested",         sign: -1 },
  { kind: "bonus",       bucket: "spend",  label: "Bonus",            sign: 1 },
  { kind: "adjustment",  bucket: "spend",  label: "Adjustment (+/−)", sign: 0 },
];
const KIND_LABELS = { opening_balance: "Starting balance", fine: "Fine" };

const STATUS = {
  claimed:     { icon: "✓", fg: T.blue,     label: "Done" },
  verified:    { icon: "✓", fg: T.green,    label: "Checked" },
  missed:      { icon: "✗", fg: T.amber,    label: "Not done" },
  false_claim: { icon: "✗", fg: T.red,      label: "Said done, wasn't" },
  excused:     { icon: "–", fg: T.slate400, label: "Excused" },
  carried:     { icon: "→", fg: T.slate500, label: "Carried" },
  picked:      { icon: "•", fg: T.blue,     label: "Picked" },
};

const money = (n) => {
  const v = Number(n);
  if (!Number.isFinite(v)) return "$0.00";
  return (v < 0 ? "−$" : "$") + Math.abs(v).toFixed(2);
};
const cents = (n) => Math.round(Number(n || 0) * 100);
const fromCents = (c) => c / 100;
const todayCentral = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
const parseDate = (s) => { const [y, m, d] = String(s).split("-").map(Number); return new Date(Date.UTC(y, m - 1, d)); };
const fmtDate = (dt) => dt.toISOString().slice(0, 10);
const addDays = (s, n) => { const d = parseDate(s); d.setUTCDate(d.getUTCDate() + n); return fmtDate(d); };
// The family chore week runs Saturday through Friday (matches family_week_start in the database).
const weekStartOf = (s) => addDays(s, -((parseDate(s).getUTCDay() + 1) % 7));
const WEEK_ORDER = [6, 0, 1, 2, 3, 4, 5];
const isDate = (s) => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
const shortDate = (s) => parseDate(s).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });

const btn = (kind = "soft", small = false) => ({
  border: `1px solid ${kind === "primary" ? T.blue : kind === "danger" ? T.red : T.slate200}`,
  background: kind === "primary" ? T.blue : T.white,
  color: kind === "primary" ? T.white : kind === "danger" ? T.red : T.slate700,
  borderRadius: 8, padding: small ? "4px 7px" : "6px 10px", fontSize: small ? 11 : 12, fontWeight: 600,
  cursor: "pointer", fontFamily: "inherit", whiteSpace: "nowrap", boxSizing: "border-box",
});
// Done and Missed are round tap targets: a check or an x in a circle.
const circle = (kind) => ({
  width: 30, height: 30, borderRadius: "50%", padding: 0, boxSizing: "border-box", cursor: "pointer",
  border: `2px solid ${kind === "done" ? T.green : T.red}`, background: T.white,
  color: kind === "done" ? T.green : T.red, fontSize: 15, fontWeight: 800, lineHeight: "26px", fontFamily: "inherit",
});
const card = { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: 14, boxSizing: "border-box" };
const input = { border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "7px 9px", fontSize: 13, fontFamily: "inherit", boxSizing: "border-box", background: T.white, color: T.slate900 };

export default function Family({ userRole }) {
  const isParent = PARENT_ROLES.includes(userRole);
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const [tab, setTab, tabHref] = useTabParam("tab", "week", TABS);
  const [kidParam, setKidParam, kidHref] = useTabParam("kid", null);
  const [dateParam, setDateParam, dateHref] = useTabParam("date", null);

  const [kids, setKids] = useState([]);
  const [chores, setChores] = useState([]);
  const [checklists, setChecklists] = useState([]);
  const [balances, setBalances] = useState([]);
  const [ledger, setLedger] = useState([]);
  const [settings, setSettings] = useState(null);
  const [fineTypes, setFineTypes] = useState([]);
  const [board, setBoard] = useState([]);
  const [extras, setExtras] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(null);
  const [celebrate, setCelebrate] = useState(null);
  const [closing, setClosing] = useState(null);

  const today = todayCentral();
  const day = isDate(dateParam) && dateParam <= today ? dateParam : today;
  const viewWeek = isDate(dateParam) ? weekStartOf(dateParam) : weekStartOf(today);
  const kid = kids.find(k => k.id === kidParam) || kids[0] || null;
  const kidId = kid?.id || null;
  const visibleTabs = isParent ? TABS : TABS.filter(t => t !== "setup" && t !== "fines");
  const activeTab = visibleTabs.includes(tab) ? tab : "week";

  const load = useCallback(async () => {
    setErr(null);
    try {
      await supabase.rpc("family_sweep_missed");
      const [k, c, cl, b, lg, s, ft] = await Promise.all([
        supabase.from("family_kids").select("*").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("family_chores").select("*").eq("agency_id", AGENCY_ID).order("sort_order"),
        supabase.from("family_checklists").select("*").eq("agency_id", AGENCY_ID),
        supabase.rpc("family_balances", { p_week_start: viewWeek }),
        supabase.from("family_ledger").select("*").eq("agency_id", AGENCY_ID).order("entry_date", { ascending: false }).order("created_at", { ascending: false }).limit(60),
        supabase.from("family_settings").select("*").eq("agency_id", AGENCY_ID).maybeSingle(),
        supabase.from("family_fine_types").select("*").eq("agency_id", AGENCY_ID).order("sort_order").order("created_at"),
      ]);
      const firstErr = [k, c, cl, b, lg, s, ft].find(r => r?.error)?.error;
      if (firstErr) throw firstErr;
      setKids(k.data || []); setChores(c.data || []); setChecklists(cl.data || []);
      setBalances(b.data || []); setLedger(lg.data || []); setSettings(s.data || null); setFineTypes(ft.data || []);
    } catch (e) {
      setErr(e?.message || String(e));
    } finally {
      setLoading(false);
    }
  }, [viewWeek]);
  useEffect(() => { load(); }, [load]);

  const loadBoard = useCallback(async () => {
    if (!kidId) { setBoard([]); return; }
    const [b, x] = await Promise.all([
      supabase.rpc("family_week_board", { p_kid_id: kidId, p_week_start: viewWeek }),
      supabase.rpc("family_extras_available", { p_date: day }),
    ]);
    if (b.error || x.error) { setErr((b.error || x.error).message); return; }
    setBoard(Array.isArray(b.data) ? b.data : []);
    setExtras(Array.isArray(x.data) ? x.data : []);
  }, [kidId, viewWeek, day]);
  useEffect(() => { loadBoard(); }, [loadBoard]);

  const todayDone = (rows) => {
    const mine = (rows || []).filter(r => r.day === today && r.frequency !== "extra");
    return mine.length > 0 && mine.every(r => DONE_STATES.includes(r.status));
  };

  const setStatus = async (row, status) => {
    const wasDone = todayDone(board);
    setBusy(row.chore_id + row.day);
    const { error } = await supabase.rpc("family_set_status", {
      p_chore_id: row.chore_id, p_occurrence_date: row.occurrence_date || row.day, p_status: status, p_kid_id: kidId,
    });
    setBusy(null);
    if (error) { setErr(error.message); return; }
    const { data } = await supabase.rpc("family_week_board", { p_kid_id: kidId, p_week_start: viewWeek });
    const rows = Array.isArray(data) ? data : board;
    setBoard(rows);
    if (!wasDone && todayDone(rows) && kid) setCelebrate(kid);
    load();
    const x = await supabase.rpc("family_extras_available", { p_date: day });
    if (!x.error) setExtras(x.data || []);
  };

  if (loading) return <div style={{ padding: _pad, color: T.slate500, fontSize: 13 }}>Loading…</div>;

  const bal = balances.find(b => b.kid_id === kidId);

  return (
    <div style={{ padding: _pad, maxWidth: 1080, margin: "0 auto", boxSizing: "border-box" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 10, marginBottom: 12 }}>
        <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900 }}>Family</div>
        <div style={{ display: "flex", gap: 6, overflowX: "auto", whiteSpace: "nowrap" }}>
          {visibleTabs.map(t => (
            <TabLink key={t} href={tabHref(t)} onSelect={() => setTab(t)}
              style={{ ...btn(activeTab === t ? "primary" : "soft"), flexShrink: 0, textDecoration: "none" }}>
              {TAB_LABELS[t]}
            </TabLink>
          ))}
        </div>
      </div>

      {err && (
        <div style={{ ...card, background: T.redLt, borderColor: T.red, color: T.red, fontSize: 13, marginBottom: 12, display: "flex", justifyContent: "space-between", gap: 8 }}>
          <span>{err}</span><button style={btn("soft", true)} onClick={() => setErr(null)}>OK</button>
        </div>
      )}

      {activeTab !== "setup" && <KidPicker kids={kids} kid={kid} balances={balances} kidHref={kidHref} setKid={setKidParam} />}

      {activeTab === "week" && kid && (
        <WeekGrid kid={kid} board={board} checklists={checklists} extras={extras} isParent={isParent}
          day={day} today={today} weekStart={viewWeek} dateHref={dateHref} setDate={setDateParam}
          busy={busy} setStatus={setStatus} balance={bal} />
      )}
      {activeTab === "money" && kid && (
        <MoneyView kid={kid} balance={bal} isParent={isParent} ledger={ledger.filter(l => l.kid_id === kid.id)}
          onSaved={load} setErr={setErr} onClose={(ws) => setClosing({ kid, ws })} />
      )}
      {activeTab === "fines" && isParent && (
        <FinesView kids={kids} fineTypes={fineTypes} fines={ledger.filter(l => l.kind === "fine")} today={today} onSaved={load} setErr={setErr} />
      )}
      {activeTab === "setup" && isParent && (
        <SetupView kids={kids} chores={chores} checklists={checklists} settings={settings} today={today} onSaved={load} setErr={setErr} />
      )}

      {closing && (
        <CloseOut kid={closing.kid} weekStart={closing.ws} isParent={isParent} setErr={setErr}
          onDone={() => { setClosing(null); load(); loadBoard(); }} onCancel={() => setClosing(null)} />
      )}
      {celebrate && <Celebration kid={celebrate} onClose={() => setCelebrate(null)} />}
    </div>
  );
}

function KidPicker({ kids, kid, balances, kidHref, setKid }) {
  return (
    <div style={{ display: "flex", gap: 8, overflowX: "auto", whiteSpace: "nowrap", paddingBottom: 4, marginBottom: 12 }}>
      {(kids || []).map(k => {
        const b = (balances || []).find(x => x.kid_id === k.id);
        const on = kid?.id === k.id;
        return (
          <TabLink key={k.id} href={kidHref(k.id)} onSelect={() => setKid(k.id)}
            style={{ flexShrink: 0, textDecoration: "none", borderRadius: 999, padding: "5px 12px 5px 6px",
              border: `1px solid ${on ? T.blue : T.slate200}`, background: on ? T.blueLt : T.white,
              color: T.slate900, fontSize: 13, fontWeight: 600, display: "inline-flex", alignItems: "center", gap: 6 }}>
            <CritterIcon which={k.animal} size={26} />
            {k.name}
            <span style={{ color: Number(b?.spend) < 0 ? T.red : T.slate500, fontWeight: 500 }}>{money(b?.spend)}</span>
          </TabLink>
        );
      })}
    </div>
  );
}

// ─── Week grid ────────────────────────────────────────────────────────────
function WeekGrid({ kid, board, checklists, extras, isParent, day, today, weekStart, dateHref, setDate, busy, setStatus, balance }) {
  const _vp = useViewport();
  const [openInfo, setOpenInfo] = useState(null);
  const [pickId, setPickId] = useState("");
  const days = Array.from({ length: 7 }, (_, i) => addDays(weekStart, i));

  const { groups, cells } = useMemo(() => {
    const meta = new Map();
    const cellMap = new Map();
    for (const r of (board || [])) {
      if (!meta.has(r.chore_id)) meta.set(r.chore_id, r);
      if (!cellMap.has(r.chore_id)) cellMap.set(r.chore_id, new Map());
      cellMap.get(r.chore_id).set(r.day, r);
    }
    const list = [...meta.values()];
    const g = [];
    for (const [key, label] of PARTS) {
      const rows = list.filter(r => r.frequency === "daily" && (r.part_of_day || "anytime") === key);
      const lock = rows.map(r => cellMap.get(r.chore_id)?.get(day)?.locked_by).find(Boolean) || null;
      if (rows.length) g.push({ key, label, rows, lock });
    }
    // This week, a weekly chore with a due day shows from that day on. Past weeks show everything.
    const thisWeek = today >= weekStart && today <= addDays(weekStart, 6);
    const weekly = list.filter(r => r.frequency === "weekly" && !(thisWeek && r.due_dow != null && r.occurrence_date > today));
    if (weekly.length) g.push({ key: "weekly", label: "Weekly", rows: weekly });
    g.push({ key: "extra", label: "Extra Chores", rows: list.filter(r => r.frequency === "extra") });
    return { groups: g, cells: cellMap };
  }, [board, day, today, weekStart]);

  const activeW = isParent ? 150 : 76;
  const pick = async () => {
    if (!pickId) return;
    await setStatus({ chore_id: pickId, day, occurrence_date: day }, "picked");
    setPickId("");
  };
  const canPick = (isParent ? day <= today : day === today) && day >= kid.tracking_start;

  const cellView = (r, d) => {
    const c = cells.get(r.chore_id)?.get(d);
    if (!c) return <span style={{ color: T.slate200 }}>·</span>;
    const anyDay = r.frequency === "weekly" && r.due_dow == null && day >= weekStart && day <= addDays(weekStart, 6);
    const active = c.can_act && (d === day || anyDay);
    const st = c.status ? STATUS[c.status] : null;
    if (!active) {
      let view;
      if (!st && c.locked_by && d === day) view = <span title={`Finish ${c.locked_by} first`} style={{ fontSize: 12 }}>🔒</span>;
      else if (!st) view = <span style={{ color: T.slate300 }}>{d < today && d >= kid.tracking_start ? "" : "·"}</span>;
      else view = <span title={`${st.label}${Number(c.amount) ? " " + money(c.amount) : ""}`} style={{ color: st.fg, fontWeight: 700 }}>{st.icon}</span>;
      // A parent taps any past cell to open that day and change it.
      if (isParent && c.can_act && d !== day) {
        const target = d === today ? null : d;
        return <TabLink href={dateHref(target)} onSelect={() => setDate(target)} title="Open this day"
          style={{ display: "block", minHeight: 22, color: "inherit", textDecoration: "none" }}>{view}</TabLink>;
      }
      return view;
    }
    return <CellActions row={c} isParent={isParent} busy={busy === c.chore_id + c.day} setStatus={setStatus} />;
  };

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ ...card, display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(110px, 1fr))", gap: 10 }}>
        <Stat label="Earned this week" value={money(balance?.week_earned)} />
        <Stat label="Fines this week" value={money(balance?.week_fines)} tone={Number(balance?.week_fines) < 0 ? "red" : null} />
        <Stat label="Could earn" value={money(balance?.week_possible)} />
      </div>

      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <TabLink href={dateHref(addDays(weekStart, -7))} onSelect={() => setDate(addDays(weekStart, -7))} style={{ ...btn(), textDecoration: "none" }} ariaLabel="Previous week">‹</TabLink>
        <div style={{ fontSize: 14, fontWeight: 600, color: T.slate900 }}>{shortDate(weekStart)} – {shortDate(addDays(weekStart, 6))}</div>
        {addDays(weekStart, 7) <= today && (
          <TabLink href={dateHref(addDays(weekStart, 7) > weekStartOf(today) ? null : addDays(weekStart, 7))}
            onSelect={() => setDate(addDays(weekStart, 7) > weekStartOf(today) ? null : addDays(weekStart, 7))}
            style={{ ...btn(), textDecoration: "none" }} ariaLabel="Next week">›</TabLink>
        )}
      </div>

      <div style={{ ...card, padding: 0, overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
        <table style={{ borderCollapse: "collapse", width: "100%", fontSize: 13 }}>
          <thead>
            <tr>
              <th style={{ position: "sticky", left: 0, background: T.white, zIndex: 1, textAlign: "left", padding: "10px", color: T.slate500, fontSize: 11, minWidth: _vp.isPhone ? 130 : 200 }}>Chore</th>
              {days.map(d => {
                const isActive = d === day;
                const clickable = isParent && d <= today;
                const label = <>{DAY_NAMES[parseDate(d).getUTCDay()]}<br /><span style={{ fontWeight: 500 }}>{Number(d.slice(8))}</span></>;
                return (
                  <th key={d} style={{ padding: "6px 4px", fontSize: 11, textAlign: "center", color: isActive ? T.blue : T.slate500,
                    background: isActive ? T.blueLt : "transparent", minWidth: isActive ? activeW : 34, boxSizing: "border-box" }}>
                    {clickable
                      ? <TabLink href={dateHref(d === today ? null : d)} onSelect={() => setDate(d === today ? null : d)} style={{ color: "inherit", textDecoration: "none", fontWeight: 700 }}>{label}</TabLink>
                      : <span style={{ fontWeight: 700 }}>{label}</span>}
                  </th>
                );
              })}
            </tr>
          </thead>
          <tbody>
            {groups.map(g => (
              <GroupRows key={g.key} g={g} days={days} day={day} cells={cells} cellView={cellView} checklists={checklists}
                openInfo={openInfo} setOpenInfo={setOpenInfo} isPhone={_vp.isPhone} />
            ))}
          </tbody>
        </table>
      </div>

      {canPick && (
        <div style={{ ...card, display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
          <div style={{ fontSize: 13, fontWeight: 600, color: T.slate700 }}>Want to earn more on {DAY_FULL[parseDate(day).getUTCDay()]}?</div>
          <select value={pickId} onChange={e => setPickId(e.target.value)} style={{ ...input, flex: "1 1 200px" }}>
            <option value="">Pick an extra chore…</option>
            {(extras || []).map(x => <option key={x.chore_id} value={x.chore_id}>{x.title} · {money(x.pay)}</option>)}
          </select>
          <button style={btn("primary")} disabled={!pickId} onClick={pick}>Add</button>
        </div>
      )}
      {day < kid.tracking_start && <div style={{ fontSize: 12, color: T.slate500 }}>Tracking for {kid.name} starts {shortDate(kid.tracking_start)}.</div>}
    </div>
  );
}

function GroupRows({ g, days, day, cells, cellView, checklists, openInfo, setOpenInfo, isPhone }) {
  if (!g.rows.length) return null;
  return (
    <>
      <tr>
        <td colSpan={8} style={{ padding: "10px 10px 4px", fontSize: 11, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.05em", borderTop: `1px solid ${T.slate100}` }}>
          {g.label}
          {g.lock && <span style={{ marginLeft: 8, color: T.amber, textTransform: "none", letterSpacing: 0 }}>Finish {g.lock} first</span>}
        </td>
      </tr>
      {g.rows.map(r => {
        const list = checklists.find(c => c.id === r.checklist_id);
        const open = openInfo === r.chore_id;
        const owed = r.is_burpees ? cells.get(r.chore_id)?.get(day)?.burpees_owed : null;
        const sub = r.is_burpees ? (owed != null ? `${owed} to do` : "10 per year of age")
          : r.frequency === "weekly" ? (r.due_dow == null ? "Any day this week" : `Due ${DAY_FULL[r.due_dow]}`)
          : Number(r.pay) > 0 ? money(r.pay) : "Expected, no pay";
        return (
          <FragmentRow key={r.chore_id}>
            <tr style={{ borderTop: `1px solid ${T.slate100}` }}>
              <td style={{ position: "sticky", left: 0, background: T.white, zIndex: 1, padding: "8px 10px", verticalAlign: "middle" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                  <span style={{ color: T.slate900, fontWeight: 500, fontSize: isPhone ? 12 : 13 }}>
                    {r.group_label && <span style={{ fontSize: 10, color: T.slate500, marginRight: 4 }}>{r.group_label}</span>}
                    {r.title}
                  </span>
                  {list && <InfoDot open={open} onClick={() => setOpenInfo(open ? null : r.chore_id)} title="How to do it" />}
                </div>
                <div style={{ fontSize: 11, color: T.slate500 }}>{r.frequency === "weekly" && Number(r.pay) > 0 ? `${money(r.pay)} · ` : ""}{sub}</div>
              </td>
              {days.map(d => (
                <td key={d} style={{ textAlign: "center", padding: "4px", background: d === day ? T.blueLt : "transparent", fontSize: 15 }}>{cellView(r, d)}</td>
              ))}
            </tr>
            {open && list && (
              <tr>
                <td colSpan={8} style={{ padding: "0 10px 10px 16px" }}>
                  <ol style={{ margin: 0, paddingLeft: 18, fontSize: 13, color: T.slate700, lineHeight: 1.7 }}>
                    {(list.items || []).map((it, i) => <li key={i}>{it}</li>)}
                  </ol>
                </td>
              </tr>
            )}
          </FragmentRow>
        );
      })}
    </>
  );
}
function FragmentRow({ children }) { return <>{children}</>; }

function CellActions({ row, isParent, busy, setStatus }) {
  const act = (s) => setStatus(row, s);
  const st = row.status ? STATUS[row.status] : null;
  const wrap = (children) => <div style={{ display: "flex", gap: 4, justifyContent: "center", flexWrap: "wrap" }}>{children}</div>;

  if (!row.status || row.status === "picked") {
    return (
      <div>
        {wrap(<>
          {!row.locked_by && <button disabled={busy} style={circle("done")} onClick={() => act("claimed")} title="Done" aria-label="Done">✓</button>}
          {isParent && row.is_burpees && !row.locked_by && <button disabled={busy} style={btn("soft", true)} onClick={() => act("carried")}>Carry</button>}
          {isParent && row.frequency !== "extra" && <button disabled={busy} style={btn("soft", true)} onClick={() => act("excused")}>Excuse</button>}
          {row.frequency !== "extra" && !row.status && <button disabled={busy} style={circle("missed")} onClick={() => act("missed")} title="Missed" aria-label="Missed">✗</button>}
          {row.status === "picked" && <button disabled={busy} style={btn("soft", true)} onClick={() => act(null)} title="Put it back">✕</button>}
        </>)}
      </div>
    );
  }
  if (isParent && row.status === "claimed") {
    return wrap(<>
      <span style={{ color: st.fg, fontWeight: 700 }}>{st.icon}</span>
      <button disabled={busy} style={circle("done")} onClick={() => act("verified")} title="Checked, it's done" aria-label="Done">✓</button>
      <button disabled={busy} style={circle("missed")} onClick={() => act("false_claim")} title="Said done, wasn't" aria-label="Missed">✗</button>
    </>);
  }
  return wrap(<>
    <span title={`${st.label}${Number(row.amount) ? " " + money(row.amount) : ""}`} style={{ color: st.fg, fontWeight: 700 }}>
      {st.icon}
    </span>
    {isParent && <button disabled={busy} style={btn("soft", true)} onClick={() => act(null)}>Undo</button>}
  </>);
}

function Celebration({ kid, onClose }) {
  const _vp = useViewport();
  const size = _vp.isPhone ? 76 : 120;
  const troupe = [kid.animal, kid.favorite_animal, "beagle", "pug"].filter(Boolean);
  useEffect(() => { const t = setTimeout(onClose, 12000); return () => clearTimeout(t); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <div onClick={onClose} style={{ position: "fixed", inset: 0, background: "rgba(255,255,255,0.92)", zIndex: 60, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 16, padding: 20, boxSizing: "border-box" }}>
      <DayDoneStyles />
      <Confetti />
      <div style={{ fontSize: _vp.isPhone ? 26 : 34, fontWeight: 800, color: T.slate900, textAlign: "center" }}>{kid.name}'s day is done!</div>
      <div style={{ display: "flex", gap: 4, flexWrap: "wrap", justifyContent: "center" }}>
        {troupe.map((w, i) => <Dancer key={w + i} which={w} size={size} delay={i * 120} />)}
      </div>
      <button style={btn("primary")} onClick={onClose}>Yay!</button>
    </div>
  );
}

// ─── Money ────────────────────────────────────────────────────────────────
function MoneyView({ kid, balance, isParent, ledger, onSaved, setErr, onClose }) {
  const [kind, setKind] = useState("payout");
  const [amount, setAmount] = useState("");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  const def = LEDGER_KINDS.find(k => k.kind === kind);

  const save = async () => {
    const n = Number(amount);
    if (!Number.isFinite(n) || n === 0) return;
    setSaving(true);
    const { error } = await supabase.from("family_ledger").insert({
      agency_id: AGENCY_ID, kid_id: kid.id, bucket: def.bucket, kind,
      amount: def.sign === 0 ? n : def.sign * Math.abs(n), note: note || null, entry_date: todayCentral(),
    });
    setSaving(false);
    if (error) { setErr(error.message); return; }
    setAmount(""); setNote(""); onSaved();
  };

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ ...card, display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(120px, 1fr))", gap: 10 }}>
        <Stat label="Spending money" value={money(balance?.spend)} tone={Number(balance?.spend) < 0 ? "red" : null} big />
        <Stat label={`Tithe (${Number(kid.tithe_pct)}%)`} value={money(balance?.tithe)} big />
        <Stat label={`Investments (${Number(kid.invest_pct)}%)`} value={money(balance?.invest)} big />
        {Number(balance?.pending_pay) > 0 && <Stat label="Paid at close-out" value={money(balance?.pending_pay)} big />}
      </div>

      {balance?.next_close && (
        <div style={{ ...card, display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 10, borderColor: T.blue }}>
          <div style={{ fontSize: 14, color: T.slate900 }}>The week of <b>{shortDate(balance.next_close)}</b> is over. Close it out to get paid.</div>
          <button style={btn("primary")} onClick={() => onClose(balance.next_close)}>Close Out Week</button>
        </div>
      )}

      {isParent && (
        <Section title="Record money in or out">
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))", gap: 8, paddingTop: 10 }}>
            <select value={kind} onChange={e => setKind(e.target.value)} style={input}>
              {LEDGER_KINDS.map(k => <option key={k.kind} value={k.kind}>{k.label}</option>)}
            </select>
            <input value={amount} onChange={e => setAmount(e.target.value)} inputMode="decimal" placeholder="Amount" style={input} />
            <input value={note} onChange={e => setNote(e.target.value)} placeholder="Note (optional)" style={input} />
            <button disabled={saving || !amount} onClick={save} style={btn("primary")}>{saving ? "Saving…" : "Save"}</button>
          </div>
        </Section>
      )}

      {ledger.length > 0 && (
        <Section title="History">
          {ledger.map(l => (
            <div key={l.id} style={{ display: "flex", justifyContent: "space-between", gap: 8, borderTop: `1px solid ${T.slate100}`, padding: "8px 0", fontSize: 13 }}>
              <div style={{ color: T.slate700 }}>{shortDate(l.entry_date)} · {LEDGER_KINDS.find(k => k.kind === l.kind)?.label || KIND_LABELS[l.kind] || l.kind}{l.note && l.note !== "Starting balance" ? ` · ${l.note}` : ""}</div>
              <div style={{ color: Number(l.amount) < 0 ? T.red : T.green, fontWeight: 600 }}>{money(l.amount)}</div>
            </div>
          ))}
        </Section>
      )}
    </div>
  );
}

// ─── Close-out: the week's money, one problem at a time ──────────────────
// Turns the register from the database into steps. Balances change only
// when a step that moves money is solved.
function buildSteps(reg) {
  const pctT = Number(reg?.tithe_pct ?? 10), pctI = Number(reg?.invest_pct ?? 10);
  const bal = { spend: cents(reg?.start?.spend), tithe: cents(reg?.start?.tithe), invest: cents(reg?.start?.invest) };
  const start = { ...bal };
  const steps = [];
  for (const e of (reg?.events || [])) {
    const amt = cents(e.amount);
    if (e.is_income) {
      const t = cents(e.tithe), iv = cents(e.invest);
      steps.push({ kind: "pct", head: e.label, text: `What is ${pctT}% of ${money(fromCents(amt))}?`, base: amt, answer: t, after: { ...bal } });
      if (pctI !== pctT) steps.push({ kind: "pct", head: e.label, text: `What is ${pctI}% of ${money(fromCents(amt))}?`, base: amt, answer: iv, after: { ...bal } });
      steps.push({ kind: "col", head: e.label, text: "Take out your tithe.", a: amt, sign: -1, b: t, after: { ...bal } });
      steps.push({ kind: "col", head: e.label, text: "Take out your investment.", a: amt - t, sign: -1, b: iv, after: { ...bal } });
      bal.tithe += t;
      steps.push({ kind: "col", head: "Tithe", text: "Add it to your tithe.", a: bal.tithe - t, sign: 1, b: t, after: { ...bal } });
      bal.invest += iv;
      steps.push({ kind: "col", head: "Investments", text: "Add it to your investments.", a: bal.invest - iv, sign: 1, b: iv, after: { ...bal } });
      const net = amt - t - iv;
      bal.spend += net;
      steps.push({ kind: "col", head: "Spending money", text: "Add the rest to your spending money.", a: bal.spend - net, sign: 1, b: net, after: { ...bal } });
    } else {
      const bucket = ["spend", "tithe", "invest"].includes(e.bucket) ? e.bucket : "spend";
      const before = bal[bucket];
      bal[bucket] += amt;
      steps.push({ kind: "col", head: e.label, text: amt < 0 ? "Take it out." : "Add it in.", a: before, sign: amt < 0 ? -1 : 1, b: Math.abs(amt), after: { ...bal } });
    }
  }
  return { steps, start, end: { ...bal } };
}

function CloseOut({ kid, weekStart, isParent, setErr, onDone, onCancel }) {
  const [reg, setReg] = useState(null);
  const [idx, setIdx] = useState(0);
  const [solved, setSolved] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    let live = true;
    supabase.rpc("family_week_register", { p_kid_id: kid.id, p_week_start: weekStart }).then(({ data, error }) => {
      if (!live) return;
      if (error) { setErr(error.message); onCancel(); return; }
      setReg(data);
    });
    return () => { live = false; };
  }, [kid.id, weekStart]); // eslint-disable-line react-hooks/exhaustive-deps

  const plan = useMemo(() => buildSteps(reg), [reg]);
  const finished = reg && idx >= plan.steps.length;
  const shown = !reg ? null : idx === 0 ? plan.start : plan.steps[Math.min(idx, plan.steps.length) - 1]?.after || plan.start;
  const step = reg && !finished ? plan.steps[idx] : null;

  const finish = async () => {
    setSaving(true);
    const { error } = await supabase.rpc("family_close_week", { p_kid_id: kid.id, p_week_start: weekStart, p_solved_by_parent: solved });
    setSaving(false);
    if (error) { setErr(error.message); return; }
    onDone();
  };

  return (
    <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.35)", zIndex: 55, display: "flex", alignItems: "flex-start", justifyContent: "center", overflowY: "auto", padding: 12, boxSizing: "border-box" }}>
      <div style={{ ...card, width: "100%", maxWidth: 640, marginTop: 20, display: "grid", gap: 14 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <CritterIcon which={kid.animal} size={30} />
            <div style={{ fontSize: 17, fontWeight: 700, color: T.slate900 }}>{kid.name} · Week of {shortDate(weekStart)}</div>
          </div>
          <div style={{ display: "flex", gap: 6 }}>
            {isParent && !finished && reg && <button style={btn()} onClick={() => { setSolved(true); setIdx(plan.steps.length); }}>Solve for Me</button>}
            <button style={btn()} onClick={onCancel}>Close</button>
          </div>
        </div>

        {!reg ? <div style={{ fontSize: 13, color: T.slate500 }}>Loading…</div> : (
          <>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(110px, 1fr))", gap: 8 }}>
              <MoneyBox label="Spending money" c={shown.spend} />
              <MoneyBox label="Tithe" c={shown.tithe} />
              <MoneyBox label="Investments" c={shown.invest} />
            </div>
            {plan.steps.length > 0 && !finished && <div style={{ fontSize: 12, color: T.slate500 }}>Step {idx + 1} of {plan.steps.length}</div>}
            {step && (
              <div style={{ display: "grid", gap: 8 }}>
                <div style={{ fontSize: 13, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.04em" }}>{step.head}</div>
                <div style={{ fontSize: 16, color: T.slate900, fontWeight: 600 }}>{step.text}</div>
                {step.kind === "pct"
                  ? <PercentStep key={idx} base={step.base} answer={step.answer} onSolved={() => setIdx(i => i + 1)} />
                  : <ColumnMath key={idx} a={step.a} sign={step.sign} b={step.b} onSolved={() => setIdx(i => i + 1)} />}
              </div>
            )}
            {finished && (
              <div style={{ display: "grid", gap: 10 }}>
                <div style={{ fontSize: 16, fontWeight: 700, color: T.green }}>
                  {plan.steps.length ? "All done. Your money is up to date." : "No money moved this week."}
                </div>
                <button style={btn("primary")} disabled={saving} onClick={finish}>{saving ? "Saving…" : "Finish Week"}</button>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}

function MoneyBox({ label, c }) {
  return (
    <div style={{ border: `1px solid ${T.slate200}`, borderRadius: 10, padding: "8px 10px", background: T.slate50 }}>
      <div style={{ fontSize: 11, color: T.slate500 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 800, color: c < 0 ? T.red : T.slate900 }}>{money(fromCents(c))}</div>
    </div>
  );
}

// Works out how to write a + sign·b as a column problem a kid can do: always
// the bigger number on top, and a plain-English line when the answer is below zero.
function planColumn(a, sign, b) {
  const r = a + sign * b;
  if (a >= 0 && sign > 0) return { top: a, bottom: b, op: "+", r, note: null };
  if (a >= 0) return a >= b
    ? { top: a, bottom: b, op: "−", r, note: null }
    : { top: b, bottom: a, op: "−", r, note: "This takes more than you have. Subtract the smaller number from the bigger one. The answer is below zero." };
  if (sign < 0) return { top: -a, bottom: b, op: "+", r, note: "You were already below zero, so this takes you further below. Add them. The answer stays below zero." };
  return b >= -a
    ? { top: b, bottom: -a, op: "−", r, note: "This pays back what you owed. Subtract what you owed from what came in." }
    : { top: -a, bottom: b, op: "−", r, note: "This pays back part of what you owe. Subtract, and the answer is still below zero." };
}
const digitsOf = (n, len) => Array.from({ length: len }, (_, i) => Math.floor(n / Math.pow(10, i)) % 10);

// Column addition or subtraction, one digit place at a time, right to left.
// Carries show up after a column is answered; borrows are made for them before
// they answer the column that needs one.
function ColumnMath({ a, sign, b, onSolved }) {
  const p = useMemo(() => planColumn(a, sign, b), [a, sign, b]);
  const res = Math.abs(p.r);
  const len = Math.max(String(p.top).length, String(p.bottom).length, String(res).length, 3);
  const ansLen = Math.max(String(res).length, 3);
  const top = digitsOf(p.top, len), bot = digitsOf(p.bottom, len), ans = digitsOf(res, len);

  const work = useMemo(() => {
    const carries = Array(len + 1).fill(0);
    const snaps = [];
    if (p.op === "+") {
      let c = 0;
      for (let i = 0; i < len; i++) { const s = top[i] + bot[i] + c; c = s >= 10 ? 1 : 0; carries[i + 1] = c; }
    } else {
      const t = [...top];
      const crossed = Array(len).fill(false);
      const ten = Array(len).fill(false);
      for (let i = 0; i < len; i++) {
        if (t[i] < bot[i]) {
          let j = i + 1;
          while (j < len && t[j] === 0) { t[j] = 9; crossed[j] = true; j++; }
          if (j < len) { t[j] -= 1; crossed[j] = true; }
          t[i] += 10; ten[i] = true;
        }
        snaps.push({ t: [...t], crossed: [...crossed], ten: [...ten] });
      }
    }
    return { carries, snaps };
  }, [p, len]); // eslint-disable-line react-hooks/exhaustive-deps

  const [place, setPlace] = useState(0);
  const [got, setGot] = useState({});
  const [wrong, setWrong] = useState(false);
  const [val, setVal] = useState("");

  const snap = p.op === "−" ? work.snaps[Math.min(place, len - 1)] : null;
  const hint = () => {
    if (p.op === "+") {
      const c = work.carries[place];
      return `${top[place]} + ${bot[place]}${c ? " + 1 carried" : ""} = ${top[place] + bot[place] + c}. Write the last digit.`;
    }
    return `${snap.t[place]} − ${bot[place]} = ${snap.t[place] - bot[place]}.`;
  };

  const tryDigit = (d) => {
    if (!/^[0-9]$/.test(d)) return;
    if (Number(d) === ans[place]) {
      const next = { ...got, [place]: Number(d) };
      setGot(next); setWrong(false); setVal("");
      if (place + 1 >= ansLen) { setPlace(ansLen); setTimeout(onSolved, 700); }
      else setPlace(place + 1);
    } else { setWrong(true); setVal(""); }
  };

  const cols = [];
  for (let i = len - 1; i >= 0; i--) { cols.push(i); if (i === 2) cols.push("."); }
  const cellW = 30;
  const colStyle = { width: cellW, textAlign: "center", fontSize: 22, fontFamily: "ui-monospace, Menlo, monospace", lineHeight: "30px", boxSizing: "border-box" };
  const doneAll = place >= ansLen;
  const showCarry = (i) => p.op === "+" && work.carries[i] && got[i - 1] !== undefined;
  const topDigit = (i) => {
    if (p.op !== "−" || !snap) return top[i];
    const s = doneAll ? work.snaps[len - 1] : snap;
    if (s.crossed[i] || s.ten[i]) return s.t[i];
    return top[i];
  };
  const isCrossed = (i) => p.op === "−" && (doneAll ? work.snaps[len - 1] : snap)?.crossed[i];
  const leading = (n, i) => i >= String(n).length && i > 2;

  return (
    <div style={{ display: "grid", gap: 10 }}>
      {p.note && <div style={{ fontSize: 13, color: T.slate700, background: T.amberLt, borderRadius: 8, padding: "8px 10px" }}>{p.note}</div>}
      <div style={{ display: "inline-grid", justifyContent: "start", overflowX: "auto" }}>
        <div style={{ display: "flex", paddingLeft: cellW }}>
          {cols.map((i, k) => i === "." ? <div key={k} style={{ ...colStyle, width: 10 }} /> : (
            <div key={k} style={{ ...colStyle, fontSize: 13, lineHeight: "16px", color: T.blue, fontWeight: 700 }}>
              {showCarry(i) ? "1" : isCrossed(i) && !leading(p.top, i) ? topDigit(i) : ""}
            </div>
          ))}
        </div>
        <div style={{ display: "flex", paddingLeft: cellW }}>
          {cols.map((i, k) => i === "." ? <div key={k} style={{ ...colStyle, width: 10 }}>.</div> : (
            <div key={k} style={{ ...colStyle, color: leading(p.top, i) ? "transparent" : T.slate900, textDecoration: isCrossed(i) ? "line-through" : "none", textDecorationColor: T.red }}>
              {(p.op === "−" && (doneAll ? work.snaps[len - 1] : snap)?.ten[i]) ? <span><sup style={{ fontSize: 11, color: T.blue }}>1</sup>{top[i]}</span> : top[i]}
            </div>
          ))}
        </div>
        <div style={{ display: "flex", borderBottom: `2px solid ${T.slate900}` }}>
          <div style={{ ...colStyle, fontWeight: 700 }}>{p.op}</div>
          {cols.map((i, k) => i === "." ? <div key={k} style={{ ...colStyle, width: 10 }}>.</div> : (
            <div key={k} style={{ ...colStyle, color: leading(p.bottom, i) ? "transparent" : T.slate900 }}>{bot[i]}</div>
          ))}
        </div>
        <div style={{ display: "flex" }}>
          <div style={{ ...colStyle, fontWeight: 700, color: T.red }}>{p.r < 0 && doneAll ? "−" : ""}</div>
          {cols.map((i, k) => {
            if (i === ".") return <div key={k} style={{ ...colStyle, width: 10 }}>.</div>;
            if (i >= ansLen) return <div key={k} style={colStyle} />;
            if (got[i] !== undefined) return <div key={k} style={{ ...colStyle, color: T.green, fontWeight: 700 }}>{got[i]}</div>;
            if (i === place) return (
              <div key={k} style={colStyle}>
                <input autoFocus value={val} inputMode="numeric" maxLength={1} aria-label="Digit"
                  onChange={e => { const d = e.target.value.slice(-1); setVal(d); tryDigit(d); }}
                  style={{ width: 26, height: 28, textAlign: "center", fontSize: 18, fontFamily: "inherit", boxSizing: "border-box", borderRadius: 6,
                    border: `2px solid ${wrong ? T.red : T.blue}`, background: wrong ? T.redLt : T.white, padding: 0 }} />
              </div>
            );
            return <div key={k} style={{ ...colStyle, color: T.slate300 }}>_</div>;
          })}
        </div>
      </div>
      {doneAll
        ? <div style={{ fontSize: 14, fontWeight: 700, color: T.green }}>Right! {money(fromCents(p.r))}</div>
        : wrong
          ? <div style={{ fontSize: 13, color: T.red }}>Not quite. Try again. {hint()}</div>
          : <div style={{ fontSize: 12, color: T.slate500 }}>Fill in the {place === 0 ? "pennies" : place === 1 ? "dimes" : place === 2 ? "dollars" : place === 3 ? "tens" : "next"} place.{p.op === "−" && snap?.ten[place] ? " We borrowed 10 for you." : ""}</div>}
    </div>
  );
}

// 10% of an amount. Fill in each digit place, then check. Rounds to the cent.
function PercentStep({ base, answer, onSolved }) {
  const len = Math.max(String(answer).length, 3);
  const want = digitsOf(answer, len);
  const [vals, setVals] = useState(Array(len).fill(""));
  const [checked, setChecked] = useState(false);
  const [tries, setTries] = useState(0);
  const places = [];
  for (let i = len - 1; i >= 0; i--) { places.push(i); if (i === 2) places.push("."); }
  const right = vals.every((v, i) => v !== "" && Number(v) === want[i]);
  const check = () => {
    setChecked(true); setTries(t => t + 1);
    if (right) setTimeout(onSolved, 700);
  };
  return (
    <div style={{ display: "grid", gap: 10 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 2, flexWrap: "wrap" }}>
        <span style={{ fontSize: 22, marginRight: 4 }}>$</span>
        {places.map((i, k) => i === "." ? <span key={k} style={{ fontSize: 22 }}>.</span> : (
          <input key={k} value={vals[i]} inputMode="numeric" maxLength={1} aria-label="Digit"
            onChange={e => { const d = e.target.value.slice(-1); if (d && !/^[0-9]$/.test(d)) return; const n = [...vals]; n[i] = d; setVals(n); setChecked(false); }}
            style={{ width: 30, height: 34, textAlign: "center", fontSize: 20, boxSizing: "border-box", borderRadius: 6, padding: 0, fontFamily: "inherit",
              border: `2px solid ${checked ? (Number(vals[i]) === want[i] && vals[i] !== "" ? T.green : T.red) : T.slate300}` }} />
        ))}
        <button style={{ ...btn("primary"), marginLeft: 8 }} disabled={vals.some(v => v === "")} onClick={check}>Check</button>
      </div>
      {checked && right && <div style={{ fontSize: 14, fontWeight: 700, color: T.green }}>Right! {money(fromCents(answer))}</div>}
      {checked && !right && (
        <div style={{ fontSize: 13, color: T.red }}>
          Not quite. 10% means move the decimal point one place to the left{tries > 1 ? `: ${money(fromCents(base))} becomes $${(base / 1000).toFixed(3)}` : ""}. Then round to the nearest cent.
        </div>
      )}
    </div>
  );
}

// ─── Chores setup (parents) ───────────────────────────────────────────────
function SetupView({ kids, chores, checklists, settings, today, onSaved, setErr }) {
  const [draft, setDraft] = useState({});
  const [adding, setAdding] = useState(null);
  const [addingExtra, setAddingExtra] = useState(null);
  const current = (k) => chores.filter(c => c.kid_id === k.id && c.frequency !== "extra" && (!c.active_to || c.active_to >= today));
  const extras = chores.filter(c => c.frequency === "extra" && (!c.active_to || c.active_to >= today));

  const saveChore = async (c) => {
    const d = draft[c.id]; if (!d) return;
    const patch = {};
    if (d.title !== undefined) patch.title = d.title;
    if (d.pay !== undefined) patch.pay = Number(d.pay) || 0;
    if (d.fine !== undefined) patch.fine = d.fine === "" ? null : Number(d.fine);
    if (d.due_dow !== undefined) patch.due_dow = d.due_dow === "" ? null : Number(d.due_dow);
    if (d.repeat_days !== undefined) patch.repeat_days = d.repeat_days === "" ? null : Math.max(1, Number(d.repeat_days) || 1);
    const { error } = await supabase.from("family_chores").update(patch).eq("id", c.id);
    if (error) { setErr(error.message); return; }
    setDraft(x => { const n = { ...x }; delete n[c.id]; return n; });
    onSaved();
  };
  const removeChore = async (c) => {
    if (!window.confirm(`Remove "${c.title}"?`)) return;
    const { count } = await supabase.from("family_chore_log").select("id", { count: "exact", head: true }).eq("chore_id", c.id);
    const res = count
      ? await supabase.from("family_chores").update({ active_to: addDays(today, -1) }).eq("id", c.id)
      : await supabase.from("family_chores").delete().eq("id", c.id);
    if (res.error) { setErr(res.error.message); return; }
    onSaved();
  };
  const addChore = async () => {
    const a = adding; if (!a?.title) return;
    const { error } = await supabase.from("family_chores").insert({
      agency_id: AGENCY_ID, kid_id: a.kid_id, title: a.title, frequency: a.frequency,
      part_of_day: a.frequency === "daily" ? a.part_of_day : null, pay: Number(a.pay) || 0,
      due_dow: a.frequency === "weekly" && a.due_dow !== "" && a.due_dow != null ? Number(a.due_dow) : null,
      checklist_id: a.checklist_id || null, sort_order: 99, active_from: today,
    });
    if (error) { setErr(error.message); return; }
    setAdding(null); onSaved();
  };
  const addExtra = async () => {
    const a = addingExtra; if (!a?.title) return;
    const { error } = await supabase.from("family_chores").insert({
      agency_id: AGENCY_ID, kid_id: null, title: a.title, frequency: "extra", pay: Number(a.pay) || 0,
      repeat_days: a.repeat_days === "" || a.repeat_days == null ? null : Math.max(1, Number(a.repeat_days) || 1),
      checklist_id: a.checklist_id || null, sort_order: 99, active_from: today,
    });
    if (error) { setErr(error.message); return; }
    setAddingExtra(null); onSaved();
  };
  const saveSetting = async (patch) => {
    const { error } = await supabase.from("family_settings").update({ ...patch, updated_at: new Date().toISOString() }).eq("agency_id", AGENCY_ID);
    if (error) setErr(error.message); else onSaved();
  };
  const saveKid = async (k, patch) => {
    const { error } = await supabase.from("family_kids").update(patch).eq("id", k.id);
    if (error) setErr(error.message); else onSaved();
  };
  const cellIn = (c, field, fallback, w = 70, placeholder) => {
    const d = draft[c.id] || {};
    return <input value={d[field] ?? (fallback ?? "")} placeholder={placeholder} inputMode={field === "title" ? "text" : "decimal"}
      onChange={e => setDraft(x => ({ ...x, [c.id]: { ...(x[c.id] || {}), [field]: e.target.value } }))}
      style={{ ...input, width: w }} />;
  };
  const th = { padding: "6px 4px", color: T.slate500, textAlign: "left", fontSize: 11 };
  const td = { padding: "6px 4px" };

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <Section title="Fines">
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: 10, paddingTop: 10, fontSize: 13, color: T.slate700 }}>
          <label>Fine for a chore not done by the end of the day
            <input key={"mf" + settings?.missed_fine} defaultValue={settings?.missed_fine ?? ""} inputMode="decimal" style={{ ...input, width: "100%", marginTop: 4 }}
              onBlur={e => Number(e.target.value) !== Number(settings?.missed_fine) && saveSetting({ missed_fine: Number(e.target.value) || 0 })} />
          </label>
          <label>Saying it's done when it isn't costs this many times the fine
            <input key={"fm" + settings?.false_claim_multiplier} defaultValue={settings?.false_claim_multiplier ?? ""} inputMode="decimal" style={{ ...input, width: "100%", marginTop: 4 }}
              onBlur={e => Number(e.target.value) !== Number(settings?.false_claim_multiplier) && saveSetting({ false_claim_multiplier: Math.max(1, Number(e.target.value) || 1) })} />
          </label>
        </div>
        <div style={{ fontSize: 12, color: T.slate500, paddingTop: 8 }}>A chore's own fine, if you set one below, wins over this.</div>
      </Section>

      <Section title="Extra Chores">
        <div style={{ fontSize: 12, color: T.slate500, paddingTop: 6 }}>Paid the moment they're done. "Comes back" is the number of days before it shows up again. Leave it blank for a one-time job.</div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch", marginTop: 8 }}>
          <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
            <thead><tr><th style={th}>Chore</th><th style={th}>Price</th><th style={th}>Comes back (days)</th><th /></tr></thead>
            <tbody>
              {extras.map(c => (
                <tr key={c.id} style={{ borderTop: `1px solid ${T.slate100}` }}>
                  <td style={{ ...td, minWidth: 180 }}>{cellIn(c, "title", c.title, "100%")}</td>
                  <td style={td}>{cellIn(c, "pay", c.pay)}</td>
                  <td style={td}>{cellIn(c, "repeat_days", c.repeat_days, 70, "once")}</td>
                  <td style={{ ...td, whiteSpace: "nowrap", textAlign: "right" }}>
                    {draft[c.id] && <button style={btn("primary")} onClick={() => saveChore(c)}>Save</button>}{" "}
                    <button style={btn()} onClick={() => removeChore(c)} aria-label="Remove">✕</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {addingExtra ? (
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 8, paddingTop: 10 }}>
            <input autoFocus value={addingExtra.title} onChange={e => setAddingExtra({ ...addingExtra, title: e.target.value })} placeholder="Extra chore" style={input} />
            <input value={addingExtra.pay} onChange={e => setAddingExtra({ ...addingExtra, pay: e.target.value })} inputMode="decimal" placeholder="Price" style={input} />
            <input value={addingExtra.repeat_days} onChange={e => setAddingExtra({ ...addingExtra, repeat_days: e.target.value })} inputMode="numeric" placeholder="Comes back (days)" style={input} />
            <select value={addingExtra.checklist_id || ""} onChange={e => setAddingExtra({ ...addingExtra, checklist_id: e.target.value || null })} style={input}>
              <option value="">No instructions</option>
              {checklists.map(cl => <option key={cl.id} value={cl.id}>{cl.name}</option>)}
            </select>
            <div style={{ display: "flex", gap: 6 }}>
              <button style={btn("primary")} onClick={addExtra} disabled={!addingExtra.title}>Add</button>
              <button style={btn()} onClick={() => setAddingExtra(null)}>Cancel</button>
            </div>
          </div>
        ) : (
          <button style={{ ...btn(), marginTop: 10 }} onClick={() => setAddingExtra({ title: "", pay: "", repeat_days: "", checklist_id: null })}>+ Add extra chore</button>
        )}
      </Section>

      {kids.map(k => (
        <Section key={k.id} title={k.name}>
          <div style={{ display: "flex", gap: 10, flexWrap: "wrap", paddingTop: 10, fontSize: 12, color: T.slate700, alignItems: "center" }}>
            <CritterIcon which={k.animal} size={28} />
            <label>Tithe % <input key={"t" + k.tithe_pct} defaultValue={k.tithe_pct} inputMode="decimal" style={{ ...input, width: 64 }}
              onBlur={e => Number(e.target.value) !== Number(k.tithe_pct) && saveKid(k, { tithe_pct: Number(e.target.value) || 0 })} /></label>
            <label>Invest % <input key={"i" + k.invest_pct} defaultValue={k.invest_pct} inputMode="decimal" style={{ ...input, width: 64 }}
              onBlur={e => Number(e.target.value) !== Number(k.invest_pct) && saveKid(k, { invest_pct: Number(e.target.value) || 0 })} /></label>
          </div>
          <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch", marginTop: 8 }}>
            <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
              <thead><tr><th style={th}>Chore</th><th style={th}>When</th><th style={th}>Pay</th><th style={th}>Fine</th><th /></tr></thead>
              <tbody>
                {current(k).map(c => {
                  const d = draft[c.id] || {};
                  return (
                    <tr key={c.id} style={{ borderTop: `1px solid ${T.slate100}` }}>
                      <td style={{ ...td, minWidth: 170 }}>{cellIn(c, "title", c.title, "100%")}</td>
                      <td style={{ ...td, color: T.slate500, whiteSpace: "nowrap" }}>
                        {c.frequency === "daily" ? (PARTS.find(p => p[0] === (c.part_of_day || "anytime"))?.[1] || "Daily") : (
                          <select value={d.due_dow ?? (c.due_dow ?? "")} onChange={e => setDraft(x => ({ ...x, [c.id]: { ...(x[c.id] || {}), due_dow: e.target.value } }))} style={{ ...input, padding: "5px 6px" }}>
                            <option value="">Any day</option>
                            {WEEK_ORDER.map(i => <option key={i} value={i}>{DAY_FULL[i]}</option>)}
                          </select>
                        )}
                        {c.group_label && <span style={{ marginLeft: 6, fontSize: 11 }}>{c.group_label}</span>}
                      </td>
                      <td style={td}>{cellIn(c, "pay", c.pay)}</td>
                      <td style={td}>{cellIn(c, "fine", c.fine, 70, "auto")}</td>
                      <td style={{ ...td, whiteSpace: "nowrap", textAlign: "right" }}>
                        {draft[c.id] && <button style={btn("primary")} onClick={() => saveChore(c)}>Save</button>}{" "}
                        <button style={btn()} onClick={() => removeChore(c)} aria-label="Remove">✕</button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {adding?.kid_id === k.id ? (
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 8, paddingTop: 10 }}>
              <input autoFocus value={adding.title} onChange={e => setAdding({ ...adding, title: e.target.value })} placeholder="Chore" style={input} />
              <select value={adding.frequency === "weekly" ? "weekly" : adding.part_of_day} style={input}
                onChange={e => setAdding({ ...adding, frequency: e.target.value === "weekly" ? "weekly" : "daily", part_of_day: e.target.value === "weekly" ? null : e.target.value })}>
                {PARTS.map(([v, l]) => <option key={v} value={v}>Daily · {l}</option>)}
                <option value="weekly">Weekly</option>
              </select>
              {adding.frequency === "weekly" && (
                <select value={adding.due_dow ?? ""} onChange={e => setAdding({ ...adding, due_dow: e.target.value })} style={input}>
                  <option value="">Any day</option>
                  {WEEK_ORDER.map(i => <option key={i} value={i}>{DAY_FULL[i]}</option>)}
                </select>
              )}
              <input value={adding.pay} onChange={e => setAdding({ ...adding, pay: e.target.value })} inputMode="decimal" placeholder="Pay" style={input} />
              <select value={adding.checklist_id || ""} onChange={e => setAdding({ ...adding, checklist_id: e.target.value || null })} style={input}>
                <option value="">No instructions</option>
                {checklists.map(cl => <option key={cl.id} value={cl.id}>{cl.name}</option>)}
              </select>
              <div style={{ display: "flex", gap: 6 }}>
                <button style={btn("primary")} onClick={addChore} disabled={!adding.title}>Add</button>
                <button style={btn()} onClick={() => setAdding(null)}>Cancel</button>
              </div>
            </div>
          ) : (
            <button style={{ ...btn(), marginTop: 10 }} onClick={() => setAdding({ kid_id: k.id, title: "", frequency: "daily", part_of_day: "morning", pay: "", due_dow: "", checklist_id: null })}>+ Add chore</button>
          )}
        </Section>
      ))}
    </div>
  );
}

// ─── Fines ────────────────────────────────────────────────────────────────
// Parents keep a list of fines and apply one to any kid. An applied fine is a
// family_ledger row (kind "fine"), so it lands in balances and the close-out
// the same way every other money event does.
function FinesView({ kids, fineTypes, fines, today, onSaved, setErr }) {
  const active = (fineTypes || []).filter(f => f.is_active);
  const [kidId, setKidId] = useState("");
  const [typeId, setTypeId] = useState("");
  const [note, setNote] = useState("");
  const [name, setName] = useState("");
  const [amount, setAmount] = useState("");
  const [saving, setSaving] = useState(false);
  const kidName = (id) => (kids || []).find(k => k.id === id)?.name || "";

  const apply = async () => {
    const t = active.find(f => f.id === typeId);
    if (!kidId || !t) return;
    setSaving(true);
    const { error } = await supabase.from("family_ledger").insert({
      agency_id: AGENCY_ID, kid_id: kidId, bucket: "spend", kind: "fine", fine_type_id: t.id,
      amount: -Math.abs(Number(t.amount)), note: note ? `${t.name} · ${note}` : t.name, entry_date: today,
    });
    setSaving(false);
    if (error) { setErr(error.message); return; }
    setNote(""); setTypeId(""); onSaved();
  };
  const addType = async () => {
    const n = Number(amount);
    if (!name.trim() || !Number.isFinite(n) || n <= 0) return;
    setSaving(true);
    const { error } = await supabase.from("family_fine_types").insert({
      agency_id: AGENCY_ID, name: name.trim(), amount: Math.abs(n), sort_order: (fineTypes || []).length + 1,
    });
    setSaving(false);
    if (error) { setErr(error.message); return; }
    setName(""); setAmount(""); onSaved();
  };
  const removeType = async (id) => {
    const { error } = await supabase.from("family_fine_types").delete().eq("id", id);
    if (error) { setErr(error.message); return; }
    onSaved();
  };
  const removeFine = async (id) => {
    const { error } = await supabase.from("family_ledger").delete().eq("id", id).eq("kind", "fine");
    if (error) { setErr(error.message); return; }
    onSaved();
  };

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <Section title="Give a fine">
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))", gap: 8, paddingTop: 10 }}>
          <select value={kidId} onChange={e => setKidId(e.target.value)} style={input}>
            <option value="">Who?</option>
            {(kids || []).map(k => <option key={k.id} value={k.id}>{k.name}</option>)}
          </select>
          <select value={typeId} onChange={e => setTypeId(e.target.value)} style={input}>
            <option value="">What for?</option>
            {active.map(f => <option key={f.id} value={f.id}>{f.name} · {money(f.amount)}</option>)}
          </select>
          <input value={note} onChange={e => setNote(e.target.value)} placeholder="Note (optional)" style={input} />
          <button disabled={saving || !kidId || !typeId} onClick={apply} style={btn("danger")}>Give fine</button>
        </div>
      </Section>

      {fines.length > 0 && (
        <Section title="Recent fines">
          {fines.map(l => (
            <div key={l.id} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, borderTop: `1px solid ${T.slate100}`, padding: "8px 0", fontSize: 13 }}>
              <div style={{ color: T.slate700 }}>{shortDate(l.entry_date)} · {kidName(l.kid_id)} · {l.note}</div>
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{ color: T.red, fontWeight: 600 }}>{money(l.amount)}</span>
                <button style={btn("soft", true)} onClick={() => removeFine(l.id)} title="Take this fine back">Undo</button>
              </div>
            </div>
          ))}
        </Section>
      )}

      <Section title="Fine list">
        {(fineTypes || []).map(f => (
          <div key={f.id} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, borderTop: `1px solid ${T.slate100}`, padding: "8px 0", fontSize: 13 }}>
            <div style={{ color: T.slate900 }}>{f.name}</div>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <span style={{ fontWeight: 600, color: T.slate700 }}>{money(f.amount)}</span>
              <button style={btn("soft", true)} onClick={() => removeType(f.id)} title="Delete this fine">✕</button>
            </div>
          </div>
        ))}
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))", gap: 8, paddingTop: 10 }}>
          <input value={name} onChange={e => setName(e.target.value)} placeholder="New fine, e.g. Talking back" style={input} />
          <input value={amount} onChange={e => setAmount(e.target.value)} inputMode="decimal" placeholder="Amount" style={input} />
          <button disabled={saving || !name.trim() || !amount} onClick={addType} style={btn("primary")}>Add fine</button>
        </div>
      </Section>
    </div>
  );
}

function Section({ title, children }) {
  return (
    <div style={card}>
      <div style={{ fontSize: 12, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.05em" }}>{title}</div>
      {children}
    </div>
  );
}

function Stat({ label, value, tone, big }) {
  return (
    <div>
      <div style={{ fontSize: 11, color: T.slate500 }}>{label}</div>
      <div style={{ fontSize: big ? 22 : 17, fontWeight: 700, color: tone === "red" ? T.red : T.slate900 }}>{value}</div>
    </div>
  );
}
