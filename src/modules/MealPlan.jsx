import { useCallback, useEffect, useMemo, useState } from "react";
import QRCode from "qrcode";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { todayISOCentral, dayOfWeekISO, addDaysISO } from "../lib/weeks.js";

// =========================================================================
// MealPlan.jsx — what's for dinner, a week at a time (Sunday to Saturday).
// Everyone who can see Family sees the week: tonight's dinner with a QR code
// for the recipe, the week list, and tomorrow. Parents can change any day,
// look at next week, add and edit meals, and approve meal ideas.
// The database does all the choosing, one function per job:
//   family_meal_week(week_start)   fills empty days from today on, returns the 7 days
//   family_meal_set_day(date, meal_id, out)   parents: change one day
//   family_meal_pick / family_meal_slot (used inside those two): chicken and beef
//   alternate, Thursday is a simple night, Friday is dinner out.
// Meals live in family_meals: status approved (on the rotation) or suggested (an idea
// waiting for a parent's yes). Parents write that table directly; the rules allow it.
// =========================================================================

const PARENT_ROLES = ["owner", "admin"];
const TABS = ["week", "admin"];
const TAB_LABELS = { week: "This week", admin: "Admin" };
const WEEKS = ["this", "next"];
const MEATS = [["chicken", "Chicken"], ["beef", "Beef"], ["pork", "Pork"], ["fish", "Fish"], ["none", "No meat"]];
const MEAT_LABEL = Object.fromEntries(MEATS);
const DAY_SHORT = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];

const card = { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 16, boxSizing: "border-box" };
const eyebrow = { fontSize: 12, fontWeight: 700, color: T.slate500, letterSpacing: "0.12em", textTransform: "uppercase" };
const input = { border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "8px 10px", fontSize: 14, fontFamily: "inherit", boxSizing: "border-box", background: T.white, color: T.slate900, width: "100%" };
const btn = (kind = "soft", small = false) => ({
  border: `1px solid ${kind === "primary" ? T.blue : kind === "danger" ? T.red : T.slate200}`,
  background: kind === "primary" ? T.blue : T.white,
  color: kind === "primary" ? T.white : kind === "danger" ? T.red : T.slate700,
  borderRadius: 8, padding: small ? "4px 9px" : "7px 12px", fontSize: small ? 12 : 13, fontWeight: 600,
  cursor: "pointer", fontFamily: "inherit", whiteSpace: "nowrap", boxSizing: "border-box",
});
const pill = (dark) => ({
  fontSize: 12, fontWeight: 600, borderRadius: 999, padding: "3px 10px", whiteSpace: "nowrap", flexShrink: 0,
  background: dark ? T.chromeBgDeep : T.slate100, color: dark ? T.white : T.slate700,
});

const shortDate = (iso) => {
  const [y, m, d] = String(iso).split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
};
const sides = (s) => String(s || "").split(",").map(x => x.trim()).filter(Boolean);

export default function MealPlan({ userRole }) {
  const isParent = PARENT_ROLES.includes(userRole);
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const [tab, setTab, tabHref] = useTabParam("tab", "week", TABS);
  const [week, setWeek] = useTabParam("week", "this", WEEKS);
  const [days, setDays] = useState([]);
  const [meals, setMeals] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);

  const today = todayISOCentral();
  const thisSunday = addDaysISO(today, -(dayOfWeekISO(today) || 0));
  const showNext = isParent && week === "next";
  const weekStart = showNext ? addDaysISO(thisSunday, 7) : thisSunday;

  const visibleTabs = isParent ? TABS : ["week"];
  const activeTab = visibleTabs.includes(tab) ? tab : "week";

  const loadWeek = useCallback(async () => {
    // Tomorrow can fall in next week (on Saturday), so this week always loads a day past it.
    const { data, error } = await supabase.rpc("family_meal_week", { p_week_start: weekStart });
    if (error) { setErr(error.message); setLoading(false); return; }
    let rows = Array.isArray(data) ? data : [];
    if (!showNext && dayOfWeekISO(today) === 6) {
      const nx = await supabase.rpc("family_meal_week", { p_week_start: addDaysISO(weekStart, 7) });
      if (!nx.error && Array.isArray(nx.data)) rows = rows.concat(nx.data.slice(0, 1));
    }
    setDays(rows);
    setLoading(false);
  }, [weekStart, showNext, today]);

  const loadMeals = useCallback(async () => {
    const { data, error } = await supabase.from("family_meals")
      .select("id, name, meat, recipe_url, served_with, is_simple, status, similar_to")
      .order("name");
    if (error) setErr(error.message);
    else setMeals(Array.isArray(data) ? data : []);
  }, []);

  useEffect(() => { loadWeek(); }, [loadWeek]);
  useEffect(() => { loadMeals(); }, [loadMeals]);

  if (loading) return <div style={{ padding: _pad, color: T.slate500, fontSize: 13 }}>Loading…</div>;

  return (
    <div style={{ padding: _pad, maxWidth: 820, margin: "0 auto", boxSizing: "border-box" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 10, marginBottom: 12 }}>
        <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900 }}>Meal Plan</div>
        {visibleTabs.length > 1 && (
          <div style={{ display: "flex", gap: 6, overflowX: "auto", whiteSpace: "nowrap" }}>
            {visibleTabs.map(t => (
              <TabLink key={t} href={tabHref(t)} onSelect={() => setTab(t)}
                style={{ ...btn(activeTab === t ? "primary" : "soft"), flexShrink: 0, textDecoration: "none" }}>
                {TAB_LABELS[t]}
              </TabLink>
            ))}
          </div>
        )}
      </div>

      {err && (
        <div style={{ ...card, background: T.redLt, borderColor: T.red, color: T.red, fontSize: 13, marginBottom: 12, display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8 }}>
          <span>{err}</span><button style={btn("soft", true)} onClick={() => setErr(null)}>OK</button>
        </div>
      )}

      {activeTab === "week" && (
        <WeekView days={days} today={today} weekStart={weekStart} showNext={showNext} isParent={isParent}
          meals={meals.filter(m => m.status === "approved")} onWeek={setWeek} onChanged={loadWeek} setErr={setErr} />
      )}
      {activeTab === "admin" && isParent && (
        <AdminView meals={meals} onChanged={() => { loadMeals(); loadWeek(); }} setErr={setErr} />
      )}
    </div>
  );
}

// ─── The week: tonight, the 7 days, tomorrow ──────────────────────────────
function WeekView({ days, today, weekStart, showNext, isParent, meals, onWeek, onChanged, setErr }) {
  const [editing, setEditing] = useState(null);
  const tonight = days.find(d => d.plan_date === today);
  const tomorrow = days.find(d => d.plan_date === addDaysISO(today, 1));
  const shown = days.filter(d => d.plan_date >= weekStart && d.plan_date <= addDaysISO(weekStart, 6));

  return (
    <div style={{ display: "grid", gap: 14 }}>
      {!showNext && tonight && <TonightCard day={tonight} />}

      <div style={{ ...card, padding: "14px 12px" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8, padding: "0 6px 10px" }}>
          <div style={eyebrow}>{showNext ? "Next week" : "This week"}</div>
          <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
            <span style={{ ...eyebrow, fontWeight: 600 }}>{shortDate(weekStart)} – {shortDate(addDaysISO(weekStart, 6))}</span>
            {isParent && (
              <button style={btn("soft", true)} onClick={() => { setEditing(null); onWeek(showNext ? "this" : "next"); }}>
                {showNext ? "‹ This week" : "Next week ›"}
              </button>
            )}
          </div>
        </div>
        <div style={{ display: "grid", gap: 6 }}>
          {shown.map(d => (
            <DayRow key={d.plan_date} day={d} today={today} isParent={isParent}
              open={editing === d.plan_date} onOpen={() => setEditing(editing === d.plan_date ? null : d.plan_date)}
              meals={meals} onChanged={() => { setEditing(null); onChanged(); }} setErr={setErr} />
          ))}
        </div>
      </div>

      {!showNext && tomorrow && (
        <div style={card}>
          <div style={eyebrow}>Tomorrow</div>
          <div style={{ fontSize: 19, fontWeight: 700, color: T.slate900, marginTop: 4 }}>
            {tomorrow.kind === "out" ? "Dinner out" : (tomorrow.name || "Not picked yet")}
          </div>
          {tomorrow.kind !== "out" && sides(tomorrow.served_with).length > 0 && (
            <div style={{ fontSize: 13, color: T.slate500, marginTop: 2 }}>With {sides(tomorrow.served_with).join(", ")}</div>
          )}
        </div>
      )}
    </div>
  );
}

function TonightCard({ day }) {
  const out = day.kind === "out";
  const list = sides(day.served_with);
  return (
    <div style={{ ...card, display: "flex", gap: 16, flexWrap: "wrap", alignItems: "center", justifyContent: "space-between" }}>
      <div style={{ flex: "1 1 220px", minWidth: 0 }}>
        <div style={eyebrow}>Tonight's dinner</div>
        <div style={{ fontSize: 28, lineHeight: 1.15, fontWeight: 800, color: T.slate900, marginTop: 6, overflowWrap: "anywhere" }}>
          {out ? "Dinner out" : (day.name || "Not picked yet")}
        </div>
        {!out && day.kind === "simple" && <div style={{ marginTop: 8 }}><span style={pill(false)}>Easy night</span></div>}
        {!out && list.length > 0 && (
          <div style={{ marginTop: 12, display: "grid", gap: 6 }}>
            {list.map(s => (
              <div key={s} style={{ display: "flex", alignItems: "center", gap: 10, fontSize: 15, color: T.slate700 }}>
                <span style={{ width: 8, height: 8, borderRadius: 999, background: T.blue, flexShrink: 0 }} />{s}
              </div>
            ))}
          </div>
        )}
        {out && <div style={{ fontSize: 15, color: T.slate500, marginTop: 8 }}>No cooking tonight.</div>}
      </div>
      {!out && day.recipe_url && <RecipeQR url={day.recipe_url} />}
    </div>
  );
}

function RecipeQR({ url }) {
  const [src, setSrc] = useState(null);
  useEffect(() => {
    let live = true;
    QRCode.toDataURL(url, { margin: 1, width: 300, color: { dark: T.slate900, light: "#FFFFFF" } })
      .then(d => { if (live) setSrc(d); })
      .catch(() => { if (live) setSrc(null); });
    return () => { live = false; };
  }, [url]);
  return (
    <a href={url} target="_blank" rel="noopener noreferrer"
      style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 6, textDecoration: "none", flexShrink: 0, margin: "0 auto" }}>
      <div style={{ width: 150, height: 150, borderRadius: 12, border: `1px solid ${T.slate200}`, background: T.white, padding: 6, boxSizing: "border-box" }}>
        {src && <img src={src} alt="QR code for the recipe" style={{ width: "100%", height: "100%", display: "block" }} />}
      </div>
      <span style={{ fontSize: 13, fontWeight: 600, color: T.blue }}>Scan for the recipe</span>
    </a>
  );
}

function DayIcon({ day, today }) {
  const past = day.plan_date < today;
  const isToday = day.plan_date === today;
  const base = { width: 32, height: 32, borderRadius: 999, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0,
    background: isToday ? T.chromeBgDeep : T.slate100, color: isToday ? T.white : T.slate600 };
  const p = { width: 16, height: 16, fill: "none", stroke: "currentColor", strokeWidth: 2, strokeLinecap: "round", strokeLinejoin: "round" };
  let icon = null;
  if (isToday) icon = <svg viewBox="0 0 24 24" style={p}><path d="M5 12h14M13 6l6 6-6 6" /></svg>;
  else if (past) icon = <svg viewBox="0 0 24 24" style={p}><path d="M5 12l5 5L20 7" /></svg>;
  else if (day.kind === "out") icon = <svg viewBox="0 0 24 24" style={p}><path d="M7 3v8M5 3v4a2 2 0 0 0 4 0V3M7 11v10M17 3c-2 0-3 2-3 5v4h3v9" /></svg>;
  else if (day.kind === "simple") icon = <svg viewBox="0 0 24 24" style={p}><path d="M13 2 4 14h7l-1 8 9-12h-7z" /></svg>;
  return <div style={base}>{icon}</div>;
}

function DayRow({ day, today, isParent, open, onOpen, meals, onChanged, setErr }) {
  const isToday = day.plan_date === today;
  const canEdit = isParent && day.plan_date >= today;
  const label = day.kind === "out" ? "Dinner out" : (day.name || "Not picked yet");
  const nameStyle = { fontSize: 16, fontWeight: isToday ? 700 : 500, color: day.plan_date < today ? T.slate500 : T.slate900, overflowWrap: "anywhere" };

  return (
    <div style={{ borderRadius: 10, border: `1px solid ${isToday ? T.blue : T.slate100}`, background: isToday ? T.blueLt : T.white }}>
      <div style={{ display: "flex", alignItems: "center", gap: 12, padding: "9px 10px", minHeight: 52, boxSizing: "border-box" }}>
        <div style={{ width: 38, fontSize: 12, fontWeight: 700, letterSpacing: "0.1em", color: T.slate500, flexShrink: 0 }}>
          {DAY_SHORT[dayOfWeekISO(day.plan_date)]}
        </div>
        <DayIcon day={day} today={today} />
        <div style={{ flex: 1, minWidth: 0 }}>
          {day.recipe_url && day.kind !== "out"
            ? <a href={day.recipe_url} target="_blank" rel="noopener noreferrer" style={{ ...nameStyle, textDecoration: "none" }}>{label}</a>
            : <span style={nameStyle}>{label}</span>}
        </div>
        {isToday && <span style={pill(true)}>Tonight</span>}
        {!isToday && day.kind === "simple" && <span style={pill(false)}>Easy night</span>}
        {canEdit && <button style={btn("soft", true)} onClick={onOpen} aria-label={`Change ${DAY_SHORT[dayOfWeekISO(day.plan_date)]}`}>{open ? "Close" : "Change"}</button>}
      </div>
      {open && canEdit && <DayEditor day={day} meals={meals} onChanged={onChanged} setErr={setErr} />}
    </div>
  );
}

function DayEditor({ day, meals, onChanged, setErr }) {
  const [pick, setPick] = useState(day.meal_id || "");
  const [busy, setBusy] = useState(false);
  const groups = useMemo(() => MEATS.map(([k, l]) => [l, meals.filter(m => m.meat === k)]).filter(([, xs]) => xs.length), [meals]);

  const run = async (args) => {
    setBusy(true);
    const { error } = await supabase.rpc("family_meal_set_day", { p_date: day.plan_date, ...args });
    setBusy(false);
    if (error) setErr(error.message);
    else onChanged();
  };

  return (
    <div style={{ padding: "0 10px 12px", display: "grid", gap: 8 }}>
      <select value={pick} onChange={e => setPick(e.target.value)} style={input} aria-label="Meal">
        <option value="">Choose a meal</option>
        {groups.map(([label, xs]) => (
          <optgroup key={label} label={label}>
            {xs.map(m => <option key={m.id} value={m.id}>{m.name}</option>)}
          </optgroup>
        ))}
      </select>
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        <button style={btn("primary")} disabled={busy || !pick || pick === day.meal_id} onClick={() => run({ p_meal_id: pick, p_out: false })}>Save</button>
        <button style={btn()} disabled={busy} onClick={() => run({ p_meal_id: null, p_out: false })}>Pick another</button>
        {day.kind !== "out" && <button style={btn()} disabled={busy} onClick={() => run({ p_meal_id: null, p_out: true })}>Dinner out</button>}
      </div>
    </div>
  );
}

// ─── Admin: meal ideas and the meal list ──────────────────────────────────
function AdminView({ meals, onChanged, setErr }) {
  const [editing, setEditing] = useState(null);
  const [q, setQ] = useState("");
  const ideas = meals.filter(m => m.status === "suggested");
  const approved = meals.filter(m => m.status === "approved");
  const needle = q.trim().toLowerCase();
  const shown = needle ? approved.filter(m => String(m.name || "").toLowerCase().includes(needle)) : approved;

  const approve = async (m) => {
    const { error } = await supabase.from("family_meals").update({ status: "approved", similar_to: null }).eq("id", m.id);
    if (error) setErr(error.message); else onChanged();
  };
  const dismiss = async (m) => {
    const { error } = await supabase.from("family_meals").delete().eq("id", m.id);
    if (error) setErr(error.message); else onChanged();
  };

  return (
    <div style={{ display: "grid", gap: 14 }}>
      {ideas.length > 0 && (
        <div style={card}>
          <div style={eyebrow}>Meal ideas</div>
          <div style={{ fontSize: 13, color: T.slate500, margin: "4px 0 10px" }}>Like meals you already make. Approve one to add it to the rotation.</div>
          <div style={{ display: "grid", gap: 8 }}>
            {ideas.map(m => (
              <div key={m.id} style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap", padding: "8px 10px", border: `1px solid ${T.slate100}`, borderRadius: 10 }}>
                <div style={{ flex: "1 1 200px", minWidth: 0 }}>
                  <a href={m.recipe_url || undefined} target="_blank" rel="noopener noreferrer" style={{ fontSize: 15, fontWeight: 600, color: T.slate900, textDecoration: "none", overflowWrap: "anywhere" }}>{m.name}</a>
                  <div style={{ fontSize: 12, color: T.slate500 }}>
                    {[MEAT_LABEL[m.meat], m.is_simple ? "Easy night" : null, m.similar_to ? `Like ${m.similar_to}` : null].filter(Boolean).join(" · ")}
                  </div>
                </div>
                <div style={{ display: "flex", gap: 6 }}>
                  <button style={btn("primary", true)} onClick={() => approve(m)}>Approve</button>
                  <button style={btn("soft", true)} onClick={() => dismiss(m)}>No thanks</button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      <div style={card}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8, marginBottom: 10 }}>
          <div style={eyebrow}>Our meals ({approved.length})</div>
          <button style={btn("primary", true)} onClick={() => setEditing({})}>Add meal</button>
        </div>
        {editing && !editing.id && <MealEditor meal={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); onChanged(); }} setErr={setErr} />}
        {approved.length > 10 && (
          <input value={q} onChange={e => setQ(e.target.value)} placeholder="Find a meal" aria-label="Find a meal" style={{ ...input, marginBottom: 8 }} />
        )}
        {MEATS.map(([k, l]) => {
          const xs = shown.filter(m => m.meat === k);
          if (!xs.length) return null;
          return (
            <div key={k} style={{ marginTop: 6 }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: T.slate500, padding: "8px 2px 4px" }}>{l}</div>
              {xs.map(m => (
                <div key={m.id} style={{ borderTop: `1px solid ${T.slate100}` }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 2px" }}>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      {m.recipe_url
                        ? <a href={m.recipe_url} target="_blank" rel="noopener noreferrer" style={{ fontSize: 15, color: T.slate900, textDecoration: "none", overflowWrap: "anywhere" }}>{m.name}</a>
                        : <span style={{ fontSize: 15, color: T.slate900 }}>{m.name}</span>}
                    </div>
                    {m.is_simple && <span style={pill(false)}>Easy night</span>}
                    <button style={btn("soft", true)} onClick={() => setEditing(editing?.id === m.id ? null : m)}>{editing?.id === m.id ? "Close" : "Edit"}</button>
                  </div>
                  {editing?.id === m.id && <MealEditor meal={m} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); onChanged(); }} setErr={setErr} />}
                </div>
              ))}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function MealEditor({ meal, onClose, onSaved, setErr }) {
  const [f, setF] = useState({
    name: meal.name || "", meat: meal.meat || "chicken", recipe_url: meal.recipe_url || "",
    served_with: meal.served_with || "", is_simple: !!meal.is_simple,
  });
  const [busy, setBusy] = useState(false);
  const set = (k) => (e) => setF(x => ({ ...x, [k]: e.target.type === "checkbox" ? e.target.checked : e.target.value }));

  const save = async () => {
    if (!f.name.trim()) return;
    setBusy(true);
    const row = {
      name: f.name.trim(), meat: f.meat, recipe_url: f.recipe_url.trim() || null,
      served_with: f.served_with.trim() || null, is_simple: f.is_simple,
    };
    const res = meal.id
      ? await supabase.from("family_meals").update(row).eq("id", meal.id)
      : await supabase.from("family_meals").insert({ ...row, agency_id: AGENCY_ID, status: "approved" });
    setBusy(false);
    if (res.error) setErr(res.error.message); else onSaved();
  };
  const remove = async () => {
    if (!window.confirm(`Delete ${meal.name}?`)) return;
    setBusy(true);
    const { error } = await supabase.from("family_meals").delete().eq("id", meal.id);
    setBusy(false);
    if (error) setErr(error.message); else onSaved();
  };

  const lab = { fontSize: 12, fontWeight: 600, color: T.slate600, display: "grid", gap: 4 };
  return (
    <div style={{ display: "grid", gap: 10, padding: "6px 2px 14px" }}>
      <label style={lab}>Meal name<input value={f.name} onChange={set("name")} style={input} autoFocus={!meal.id} /></label>
      <label style={lab}>Meat
        <select value={f.meat} onChange={set("meat")} style={input}>
          {MEATS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
        </select>
      </label>
      <label style={lab}>Link to recipe<input value={f.recipe_url} onChange={set("recipe_url")} style={input} placeholder="https://" inputMode="url" /></label>
      <label style={lab}>Served with<input value={f.served_with} onChange={set("served_with")} style={input} placeholder="Rice, salad" /></label>
      <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 14, color: T.slate700 }}>
        <input type="checkbox" checked={f.is_simple} onChange={set("is_simple")} /> Easy enough for Thursday
      </label>
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        <button style={btn("primary")} disabled={busy || !f.name.trim()} onClick={save}>Save</button>
        <button style={btn()} disabled={busy} onClick={onClose}>Cancel</button>
        {meal.id && <button style={{ ...btn("danger"), marginLeft: "auto" }} disabled={busy} onClick={remove}>Delete</button>}
      </div>
    </div>
  );
}
