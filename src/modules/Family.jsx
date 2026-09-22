import { useCallback, useEffect, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";

// =========================================================================
// Family.jsx — kids' chores and chore money.
// All money math lives in the database, one function per job:
//   family_set_status()   records an outcome and snapshots its dollar effect
//   family_sweep_missed() marks past, unlogged chores missed (with the fine)
//   family_balances()     spend / tithe / invest per kid
//   family_board()        what shows for one kid on one day, with due dates
// This screen never computes a fine, a balance, or a due date itself.
// The family login (role "family") sees This week + Money only and cannot excuse.
// Week runs Sunday to Saturday, dates in Central time.
// =========================================================================

const TABS = ["week", "money", "setup"];
const TAB_LABELS = { week: "This week", money: "Money", setup: "Chores" };
const PARTS = [["morning", "Morning"], ["afternoon", "Afternoon"], ["evening", "Evening"]];
const DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const DAY_FULL = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const PARENT_ROLES = ["owner", "manager"];
const LEDGER_KINDS = [
  { kind: "payout",      bucket: "spend",  label: "Paid out cash",   sign: -1 },
  { kind: "tithe_given", bucket: "tithe",  label: "Gave tithe",      sign: -1 },
  { kind: "invested",    bucket: "invest", label: "Invested",        sign: -1 },
  { kind: "bonus",       bucket: "spend",  label: "Bonus",           sign: 1 },
  { kind: "adjustment",  bucket: "spend",  label: "Adjustment (+/−)", sign: 0 },
];
const KIND_LABELS = { opening_balance: "Starting balance" };

const money = (n) => {
  const v = Number(n);
  if (!Number.isFinite(v)) return "$0.00";
  return (v < 0 ? "−$" : "$") + Math.abs(v).toFixed(2);
};
const todayCentral = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
const parseDate = (s) => { const [y, m, d] = String(s).split("-").map(Number); return new Date(Date.UTC(y, m - 1, d)); };
const fmtDate = (dt) => dt.toISOString().slice(0, 10);
const addDays = (s, n) => { const d = parseDate(s); d.setUTCDate(d.getUTCDate() + n); return fmtDate(d); };
const weekStartOf = (s) => addDays(s, -parseDate(s).getUTCDay());
const isDate = (s) => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);

const STATUS = {
  claimed:     { label: "Says done",           bg: T.blueLt,  fg: T.blue },
  verified:    { label: "Checked",             bg: T.greenLt, fg: T.green },
  missed:      { label: "Missed",              bg: T.amberLt, fg: T.amber },
  false_claim: { label: "Said done, wasn't",   bg: T.redLt,   fg: T.red },
  excused:     { label: "Excused",             bg: T.slate100, fg: T.slate500 },
};

const btn = (kind = "soft") => ({
  border: `1px solid ${kind === "primary" ? T.blue : kind === "danger" ? T.red : T.slate200}`,
  background: kind === "primary" ? T.blue : T.white,
  color: kind === "primary" ? T.white : kind === "danger" ? T.red : T.slate700,
  borderRadius: 8, padding: "6px 10px", fontSize: 12, fontWeight: 600,
  cursor: "pointer", fontFamily: "inherit", whiteSpace: "nowrap", boxSizing: "border-box",
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
  const [board, setBoard] = useState([]);
  const [checklists, setChecklists] = useState([]);
  const [balances, setBalances] = useState([]);
  const [ledger, setLedger] = useState([]);
  const [settings, setSettings] = useState(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(null);
  const [openChecklist, setOpenChecklist] = useState(null);

  const today = todayCentral();
  const day = isDate(dateParam) ? dateParam : today;
  const weekStart = weekStartOf(day);
  const kid = kids.find(k => k.id === kidParam) || kids[0] || null;
  const visibleTabs = isParent ? TABS : TABS.filter(t => t !== "setup");
  const activeTab = visibleTabs.includes(tab) ? tab : "week";

  const load = useCallback(async () => {
    setErr(null);
    try {
      await supabase.rpc("family_sweep_missed");
      const [k, c, cl, b, lg, s] = await Promise.all([
        supabase.from("family_kids").select("*").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("family_chores").select("*").eq("agency_id", AGENCY_ID).order("sort_order"),
        supabase.from("family_checklists").select("*").eq("agency_id", AGENCY_ID),
        supabase.rpc("family_balances", { p_week_start: weekStart }),
        supabase.from("family_ledger").select("*").eq("agency_id", AGENCY_ID).order("entry_date", { ascending: false }).order("created_at", { ascending: false }).limit(50),
        supabase.from("family_settings").select("*").eq("agency_id", AGENCY_ID).maybeSingle(),
      ]);
      const firstErr = [k, c, cl, b, lg, s].find(r => r?.error)?.error;
      if (firstErr) throw firstErr;
      setKids(k.data || []); setChores(c.data || []);
      setChecklists(cl.data || []); setBalances(b.data || []); setLedger(lg.data || []);
      setSettings(s.data || null);
    } catch (e) {
      setErr(e?.message || String(e));
    } finally {
      setLoading(false);
    }
  }, [weekStart]);

  useEffect(() => { load(); }, [load]);

  const kidId = kid?.id || null;
  const loadBoard = useCallback(async () => {
    if (!kidId) { setBoard([]); return; }
    const { data, error } = await supabase.rpc("family_board", { p_kid_id: kidId, p_date: day });
    if (error) { setErr(error.message); return; }
    setBoard(Array.isArray(data) ? data : []);
  }, [kidId, day]);
  useEffect(() => { loadBoard(); }, [loadBoard]);

  const setStatus = async (row, status) => {
    setBusy(row.chore_id);
    const { error } = await supabase.rpc("family_set_status", { p_chore_id: row.chore_id, p_occurrence_date: row.occurrence_date, p_status: status });
    setBusy(null);
    if (error) { setErr(error.message); return; }
    load(); loadBoard();
  };

  if (loading) return <div style={{ padding: _pad, color: T.slate500, fontSize: 13 }}>Loading…</div>;

  return (
    <div style={{ padding: _pad, maxWidth: 980, margin: "0 auto", boxSizing: "border-box" }}>
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

      {err && <div style={{ ...card, background: T.redLt, borderColor: T.red, color: T.red, fontSize: 13, marginBottom: 12 }}>{err}</div>}

      {activeTab !== "setup" && (
        <KidPicker kids={kids} kid={kid} balances={balances} kidHref={kidHref} setKid={setKidParam} />
      )}

      {activeTab === "week" && kid && (
        <WeekView
          kid={kid} board={board} checklists={checklists} isParent={isParent}
          day={day} today={today} weekStart={weekStart} dateHref={dateHref} setDate={setDateParam}
          busy={busy} setStatus={setStatus} openChecklist={openChecklist} setOpenChecklist={setOpenChecklist}
          balance={balances.find(b => b.kid_id === kid.id)}
        />
      )}
      {activeTab === "money" && kid && (
        <MoneyView kid={kid} balance={balances.find(b => b.kid_id === kid.id)}
          ledger={ledger.filter(l => l.kid_id === kid.id)} onSaved={load} setErr={setErr} />
      )}
      {activeTab === "setup" && isParent && (
        <SetupView kids={kids} chores={chores} checklists={checklists} settings={settings}
          today={today} onSaved={load} setErr={setErr} />
      )}
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
            style={{ flexShrink: 0, textDecoration: "none", borderRadius: 999, padding: "8px 14px",
              border: `1px solid ${on ? T.blue : T.slate200}`, background: on ? T.blueLt : T.white,
              color: T.slate900, fontSize: 13, fontWeight: 600 }}>
            {k.name} <span style={{ color: Number(b?.spend) < 0 ? T.red : T.slate500, fontWeight: 500, marginLeft: 4 }}>{money(b?.spend)}</span>
          </TabLink>
        );
      })}
    </div>
  );
}

function WeekView({ kid, board, checklists, isParent, day, today, weekStart, dateHref, setDate, busy, setStatus, openChecklist, setOpenChecklist, balance }) {
  const rows = Array.isArray(board) ? board : [];
  const daily = rows.filter(r => r.frequency === "daily");
  const dueToday = rows.filter(r => r.frequency === "weekly" && r.due_dow != null);
  const anyDay = rows.filter(r => r.frequency === "weekly" && r.due_dow == null);
  const days = Array.from({ length: 7 }, (_, i) => addDays(weekStart, i));

  const row = (r) => (
    <ChoreRow key={r.chore_id} row={r} isParent={isParent}
      checklist={checklists.find(x => x.id === r.checklist_id)}
      busy={busy === r.chore_id} setStatus={setStatus}
      open={openChecklist === r.chore_id} toggle={() => setOpenChecklist(openChecklist === r.chore_id ? null : r.chore_id)} />
  );

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ ...card, display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(110px, 1fr))", gap: 10 }}>
        <Stat label="Earned this week" value={money(balance?.week_earned)} />
        <Stat label="Fines this week" value={money(balance?.week_fines)} tone={Number(balance?.week_fines) < 0 ? "red" : null} />
        <Stat label="Could earn" value={money(balance?.week_possible)} />
      </div>

      <div style={{ display: "flex", alignItems: "center", gap: 6, overflowX: "auto", whiteSpace: "nowrap" }}>
        <TabLink href={dateHref(addDays(weekStart, -7))} onSelect={() => setDate(addDays(weekStart, -7))} style={{ ...btn(), flexShrink: 0, textDecoration: "none" }} ariaLabel="Previous week">‹</TabLink>
        {days.map(d => (
          <TabLink key={d} href={dateHref(d === today ? null : d)} onSelect={() => setDate(d === today ? null : d)}
            style={{ ...btn(d === day ? "primary" : "soft"), flexShrink: 0, textDecoration: "none", minWidth: 48, textAlign: "center" }}>
            {DAY_NAMES[parseDate(d).getUTCDay()]}<br /><span style={{ fontWeight: 500, fontSize: 11 }}>{Number(d.slice(8))}</span>
          </TabLink>
        ))}
        <TabLink href={dateHref(addDays(weekStart, 7))} onSelect={() => setDate(addDays(weekStart, 7))} style={{ ...btn(), flexShrink: 0, textDecoration: "none" }} ariaLabel="Next week">›</TabLink>
      </div>

      {day < kid.tracking_start && (
        <div style={{ fontSize: 12, color: T.slate500 }}>Tracking for {kid.name} starts {kid.tracking_start}.</div>
      )}

      {PARTS.map(([key, label]) => {
        const list = daily.filter(r => r.part_of_day === key);
        if (!list.length) return null;
        return <Section key={key} title={label}>{list.map(row)}</Section>;
      })}

      {dueToday.length > 0 && <Section title={`Weekly · due ${DAY_FULL[parseDate(day).getUTCDay()]}`}>{dueToday.map(row)}</Section>}
      {anyDay.length > 0 && <Section title="Weekly · any day, due by Saturday">{anyDay.map(row)}</Section>}
    </div>
  );
}

function ChoreRow({ row, isParent, checklist, busy, setStatus, open, toggle }) {
  const st = row.status ? STATUS[row.status] : null;
  const act = (s) => setStatus(row, s);
  const canAct = !!row.can_act;
  return (
    <div style={{ borderTop: `1px solid ${T.slate100}`, padding: "10px 0" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
        <div style={{ flex: "1 1 180px", minWidth: 0 }}>
          <div style={{ fontSize: 14, color: T.slate900, fontWeight: 500 }}>
            {row.group_label && <span style={{ fontSize: 11, color: T.slate500, marginRight: 6 }}>{row.group_label}</span>}
            {row.title}
            {checklist && (
              <button onClick={toggle} style={{ border: "none", background: "none", color: T.blue, fontSize: 12, cursor: "pointer", marginLeft: 6, padding: 0, fontFamily: "inherit" }}>
                {open ? "hide list" : "list"}
              </button>
            )}
          </div>
          <div style={{ fontSize: 12, color: T.slate500 }}>{Number(row.pay) > 0 ? money(row.pay) : "Expected, no pay"}</div>
        </div>
        {st && (
          <span style={{ background: st.bg, color: st.fg, borderRadius: 999, padding: "3px 9px", fontSize: 12, fontWeight: 600 }}>
            {st.label} {Number(row.amount) !== 0 && money(row.amount)}
          </span>
        )}
        {canAct && (
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            {!row.status && <button disabled={busy} style={btn("primary")} onClick={() => act("claimed")}>Done</button>}
            {!row.status && isParent && <button disabled={busy} style={btn()} onClick={() => act("excused")}>Excuse</button>}
            {row.status === "claimed" && <button disabled={busy} style={btn("primary")} onClick={() => act("verified")}>Checked</button>}
            {row.status === "claimed" && <button disabled={busy} style={btn("danger")} onClick={() => act("false_claim")}>Wasn't done</button>}
            {row.status === "missed" && <button disabled={busy} style={btn()} onClick={() => act("claimed")}>Done late</button>}
            {row.status === "missed" && isParent && <button disabled={busy} style={btn()} onClick={() => act("excused")}>Excuse</button>}
            {row.status && row.status !== "missed" && <button disabled={busy} style={btn()} onClick={() => act(null)}>Undo</button>}
          </div>
        )}
      </div>
      {open && checklist && (
        <ul style={{ margin: "8px 0 0 0", paddingLeft: 20, fontSize: 13, color: T.slate700, lineHeight: 1.7 }}>
          {(checklist.items || []).map((it, i) => <li key={i}>{it}</li>)}
        </ul>
      )}
    </div>
  );
}

function MoneyView({ kid, balance, ledger, onSaved, setErr }) {
  const [kind, setKind] = useState("payout");
  const [amount, setAmount] = useState("");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  const def = LEDGER_KINDS.find(k => k.kind === kind);

  const save = async () => {
    const n = Number(amount);
    if (!Number.isFinite(n) || n === 0) return;
    const signed = def.sign === 0 ? n : def.sign * Math.abs(n);
    setSaving(true);
    const { error } = await supabase.from("family_ledger").insert({
      agency_id: AGENCY_ID, kid_id: kid.id, bucket: def.bucket, kind, amount: signed, note: note || null,
      entry_date: todayCentral(),
    });
    setSaving(false);
    if (error) { setErr(error.message); return; }
    setAmount(""); setNote(""); onSaved();
  };

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ ...card, display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(110px, 1fr))", gap: 10 }}>
        <Stat label="Spending money" value={money(balance?.spend)} tone={Number(balance?.spend) < 0 ? "red" : null} big />
        <Stat label={`Tithe (${Number(kid.tithe_pct)}%)`} value={money(balance?.tithe)} big />
        <Stat label={`Invest (${Number(kid.invest_pct)}%)`} value={money(balance?.invest)} big />
      </div>

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

      {ledger.length > 0 && (
        <Section title="History">
          {ledger.map(l => (
            <div key={l.id} style={{ display: "flex", justifyContent: "space-between", gap: 8, borderTop: `1px solid ${T.slate100}`, padding: "8px 0", fontSize: 13 }}>
              <div style={{ color: T.slate700 }}>
                {l.entry_date} · {LEDGER_KINDS.find(k => k.kind === l.kind)?.label || KIND_LABELS[l.kind] || l.kind}{l.note ? ` · ${l.note}` : ""}
              </div>
              <div style={{ color: Number(l.amount) < 0 ? T.red : T.green, fontWeight: 600 }}>{money(l.amount)}</div>
            </div>
          ))}
        </Section>
      )}
    </div>
  );
}

function SetupView({ kids, chores, checklists, settings, today, onSaved, setErr }) {
  const [draft, setDraft] = useState({});
  const [adding, setAdding] = useState(null);
  const current = (k) => chores.filter(c => c.kid_id === k.id && (!c.active_to || c.active_to >= today));

  const saveChore = async (c) => {
    const d = draft[c.id]; if (!d) return;
    const patch = {};
    if (d.pay !== undefined) patch.pay = Number(d.pay) || 0;
    if (d.fine !== undefined) patch.fine = d.fine === "" ? null : Number(d.fine);
    if (d.title !== undefined) patch.title = d.title;
    if (d.due_dow !== undefined) patch.due_dow = d.due_dow === "" ? null : Number(d.due_dow);
    const { error } = await supabase.from("family_chores").update(patch).eq("id", c.id);
    if (error) { setErr(error.message); return; }
    setDraft(x => { const n = { ...x }; delete n[c.id]; return n; });
    onSaved();
  };

  const removeChore = async (c) => {
    if (!window.confirm(`Remove "${c.title}" from ${kids.find(k => k.id === c.kid_id)?.name}'s chores?`)) return;
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

  const saveSetting = async (patch) => {
    const { error } = await supabase.from("family_settings").update({ ...patch, updated_at: new Date().toISOString() }).eq("agency_id", AGENCY_ID);
    if (error) setErr(error.message); else onSaved();
  };
  const saveKid = async (k, patch) => {
    const { error } = await supabase.from("family_kids").update(patch).eq("id", k.id);
    if (error) setErr(error.message); else onSaved();
  };

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <Section title="Fines">
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: 10, paddingTop: 10, fontSize: 13, color: T.slate700 }}>
          <label>Smallest fine for a skipped chore
            <input key={"mf" + settings?.min_fine} defaultValue={settings?.min_fine ?? ""} inputMode="decimal" style={{ ...input, width: "100%", marginTop: 4 }}
              onBlur={e => Number(e.target.value) !== Number(settings?.min_fine) && saveSetting({ min_fine: Number(e.target.value) || 0 })} />
          </label>
          <label>Saying it's done when it isn't costs this many times the fine
            <input key={"fm" + settings?.false_claim_multiplier} defaultValue={settings?.false_claim_multiplier ?? ""} inputMode="decimal" style={{ ...input, width: "100%", marginTop: 4 }}
              onBlur={e => Number(e.target.value) !== Number(settings?.false_claim_multiplier) && saveSetting({ false_claim_multiplier: Math.max(1, Number(e.target.value) || 1) })} />
          </label>
        </div>
        <div style={{ fontSize: 12, color: T.slate500, paddingTop: 8 }}>A skipped chore loses its pay and costs its own fine, or its pay if no fine is set, never less than the smallest fine.</div>
      </Section>

      {kids.map(k => (
        <Section key={k.id} title={k.name}>
          <div style={{ display: "flex", gap: 10, flexWrap: "wrap", paddingTop: 10, fontSize: 12, color: T.slate700 }}>
            <label>Tithe % <input key={"t" + k.tithe_pct} defaultValue={k.tithe_pct} inputMode="decimal" style={{ ...input, width: 64 }}
              onBlur={e => Number(e.target.value) !== Number(k.tithe_pct) && saveKid(k, { tithe_pct: Number(e.target.value) || 0 })} /></label>
            <label>Invest % <input key={"i" + k.invest_pct} defaultValue={k.invest_pct} inputMode="decimal" style={{ ...input, width: 64 }}
              onBlur={e => Number(e.target.value) !== Number(k.invest_pct) && saveKid(k, { invest_pct: Number(e.target.value) || 0 })} /></label>
          </div>
          <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch", marginTop: 8 }}>
            <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
              <thead>
                <tr style={{ color: T.slate500, textAlign: "left", fontSize: 11 }}>
                  <th style={{ padding: "6px 4px" }}>Chore</th><th style={{ padding: "6px 4px" }}>When</th>
                  <th style={{ padding: "6px 4px" }}>Pay</th><th style={{ padding: "6px 4px" }}>Fine</th><th />
                </tr>
              </thead>
              <tbody>
                {current(k).map(c => {
                  const d = draft[c.id] || {};
                  const set = (f, v) => setDraft(x => ({ ...x, [c.id]: { ...(x[c.id] || {}), [f]: v } }));
                  return (
                    <tr key={c.id} style={{ borderTop: `1px solid ${T.slate100}` }}>
                      <td style={{ padding: "6px 4px", minWidth: 160 }}>
                        <input value={d.title ?? c.title} onChange={e => set("title", e.target.value)} style={{ ...input, width: "100%" }} />
                      </td>
                      <td style={{ padding: "6px 4px", color: T.slate500, whiteSpace: "nowrap" }}>
                        {c.frequency === "daily" ? (PARTS.find(p => p[0] === c.part_of_day)?.[1] || "Daily") : (
                          <select value={d.due_dow ?? (c.due_dow ?? "")} onChange={e => set("due_dow", e.target.value)} style={{ ...input, padding: "5px 6px" }}>
                            <option value="">Any day</option>
                            {DAY_FULL.map((n, i) => <option key={n} value={i}>{n}</option>)}
                          </select>
                        )}
                        {c.group_label && <span style={{ marginLeft: 6, fontSize: 11 }}>{c.group_label}</span>}
                      </td>
                      <td style={{ padding: "6px 4px" }}>
                        <input value={d.pay ?? c.pay} onChange={e => set("pay", e.target.value)} inputMode="decimal" style={{ ...input, width: 70 }} />
                      </td>
                      <td style={{ padding: "6px 4px" }}>
                        <input value={d.fine ?? (c.fine ?? "")} onChange={e => set("fine", e.target.value)} inputMode="decimal" placeholder="auto" style={{ ...input, width: 70 }} />
                      </td>
                      <td style={{ padding: "6px 4px", whiteSpace: "nowrap", textAlign: "right" }}>
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
                  {DAY_FULL.map((n, i) => <option key={n} value={i}>{n}</option>)}
                </select>
              )}
              <input value={adding.pay} onChange={e => setAdding({ ...adding, pay: e.target.value })} inputMode="decimal" placeholder="Pay" style={input} />
              <select value={adding.checklist_id || ""} onChange={e => setAdding({ ...adding, checklist_id: e.target.value || null })} style={input}>
                <option value="">No checklist</option>
                {checklists.map(cl => <option key={cl.id} value={cl.id}>{cl.name}</option>)}
              </select>
              <div style={{ display: "flex", gap: 6 }}>
                <button style={btn("primary")} onClick={addChore} disabled={!adding.title}>Add</button>
                <button style={btn()} onClick={() => setAdding(null)}>Cancel</button>
              </div>
            </div>
          ) : (
            <button style={{ ...btn(), marginTop: 10 }} onClick={() => setAdding({ kid_id: k.id, title: "", frequency: "daily", part_of_day: "morning", pay: "", checklist_id: null })}>+ Add chore</button>
          )}
        </Section>
      ))}
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
