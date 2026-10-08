import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { DayDoneStyles, Dancer, CritterIcon, useDancers } from "../components/Critters.jsx";

// =========================================================================
// Inventory.jsx — the master shopping list for stocking the house.
// Anyone who can see Family taps "Running low" on an item, and a random
// dancing character from the dancers table joins it in line until it is ordered.
// Parents get the Admin tab: what to order this week (tapped items plus the
// ones expected to run out before next week's order) and every item's preset.
// Every number on this screen comes from the database, one function per job:
//   family_inventory_board(place)   per item: tapped or not, how long one usual amount lasts
//                                   now, days left, the day it runs out, how much to buy.
//                                   place = home (the house) or office (the agency office)
//   family_inventory_mark_low()     Running low (stores which dancer)
//   family_inventory_unmark_low()   Undo
//   family_inventory_mark_ordered() parents: these were ordered, this much of each
//   family_inventory_mark_left()    parents: not out yet, this much is left
//   family_meal_grocery()           parents, Wednesday to Friday: next week's meals (Sat-Fri)
//                                   as a grocery list, checked against this inventory
// Changing an item's amount or schedule restarts its learning (database trigger).
// Items keep the master list's store sections and order. "How often" may be blank:
// the site then learns it from use and predicts nothing until it has measured a cycle.
//
// The same screen runs the office list (Peter 2026-10-08). The team's "Office" page
// (place="office") shows the office checklist plus two requests:
//   office_request_snack()   puts a snack on the office list if it's new, then taps it Running low
//   prize_cart_idea_add()    a prize idea; it goes to Alvi with the quarter's prize cart close
//   prize_cart_ideas_mine()  the person's own ideas that haven't gone to Alvi yet
//   prize_cart_idea_remove() take one back before it goes
// Alvi orders both lists from Inventory > Admin, which shows Home and Office apart.
// =========================================================================

const PARENT_ROLES = ["owner", "admin"];
const TABS = ["checklist", "admin"];
const PLACES = ["home", "office"];
const PLACE_LABELS = { home: "Home", office: "Office" };
const TAB_LABELS = { checklist: "Checklist", admin: "Admin" };
// "Still have some": how much is left, as a share of what you usually buy.
const LEFT_CHOICES = [["A little", 0.25], ["About half", 0.5], ["Plenty", 1]];

const sectionHead = { fontSize: 12, fontWeight: 700, color: T.slate500, letterSpacing: "0.05em", padding: "14px 8px 6px" };
const card = { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: 14, boxSizing: "border-box" };
const input = { border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "7px 9px", fontSize: 13, fontFamily: "inherit", boxSizing: "border-box", background: T.white, color: T.slate900 };
const btn = (kind = "soft", small = false) => ({
  border: `1px solid ${kind === "primary" ? T.blue : kind === "danger" ? T.red : T.slate200}`,
  background: kind === "primary" ? T.blue : T.white,
  color: kind === "primary" ? T.white : kind === "danger" ? T.red : T.slate700,
  borderRadius: 8, padding: small ? "4px 8px" : "7px 12px", fontSize: small ? 12 : 13, fontWeight: 600,
  cursor: "pointer", fontFamily: "inherit", whiteSpace: "nowrap", boxSizing: "border-box",
});

const num = (n) => {
  const v = Number(n);
  return Number.isFinite(v) ? String(Math.round(v * 100) / 100) : "";
};
const qtyText = (n, unit) => [num(n), unit].filter(Boolean).join(" ");
const everyText = (days) => {
  const d = Number(days);
  if (!Number.isFinite(d) || d <= 0) return "";
  if (d === 1) return "every day";
  if (d === 7) return "every week";
  if (d % 7 === 0) return `every ${d / 7} weeks`;
  return `every ${num(d)} days`;
};
const lastsText = (days) => {
  const d = Number(days);
  if (!Number.isFinite(d) || d <= 0) return "";
  if (d < 1.5) return "about a day";
  if (d < 13.5) return `about ${Math.round(d)} days`;
  const w = Math.round((d / 7) * 2) / 2;
  return `about ${w} weeks`;
};
// A random dancer from the dancers table, preferring one not already dancing on this list.
const pickDancer = (rows, allDancers, alsoInUse = []) => {
  const inUse = new Set([...(rows || []).filter(x => x.is_low && x.dancer).map(x => x.dancer), ...alsoInUse]);
  const free = (allDancers || []).filter(d => !inUse.has(d.key));
  const pool = free.length ? free : (allDancers || []);
  return pool.length ? pool[Math.floor(Math.random() * pool.length)].key : null;
};
const todayCentral = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
const utcDay = (s) => { const [y, m, d] = String(s).split("-").map(Number); return Date.UTC(y, m - 1, d); };
const outText = (r, today) => {
  const left = Number(r.days_left);
  if (!Number.isFinite(left) || left <= 0 || !r.out_on) return "Out now";
  const diff = Math.round((utcDay(r.out_on) - utcDay(today)) / 86400000);
  if (diff <= 0) return "Out today";
  if (diff === 1) return "Out tomorrow";
  if (diff >= 7) return "Out in a week";
  return `Out by ${new Date(utcDay(r.out_on)).toLocaleDateString("en-US", { weekday: "long", timeZone: "UTC" })}`;
};

export default function Inventory({ userRole, place: pagePlace = "home" }) {
  const isParent = PARENT_ROLES.includes(userRole);
  const isOfficePage = pagePlace === "office";
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const [tab, setTab, tabHref] = useTabParam("tab", "checklist", TABS);
  const [adminPlace, setAdminPlace, placeHref] = useTabParam("place", "home", PLACES);
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(null);
  const [editing, setEditing] = useState(null);
  const { all: allDancers } = useDancers();

  const visibleTabs = isParent && !isOfficePage ? TABS : ["checklist"];
  const activeTab = visibleTabs.includes(tab) ? tab : "checklist";
  // Which list is on screen: the Office page always shows the office; Inventory shows the house,
  // except on Admin, where Alvi switches between Home and Office.
  const place = isOfficePage ? "office" : activeTab === "admin" ? adminPlace : "home";

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("family_inventory_board", { p_location: place });
    if (error) setErr(error.message);
    else setRows(Array.isArray(data) ? data : []);
    setLoading(false);
  }, [place]);
  useEffect(() => { setLoading(true); load(); }, [load]);  // runs again only when the list on screen changes

  // The dancer is picked here, from the dancers table (read through useDancers).
  // It prefers one that isn't already dancing on another item.
  const toggleLow = async (r) => {
    if (busy) return;
    setBusy(r.item_id);
    let res;
    if (r.is_low) {
      setRows(xs => xs.map(x => (x.item_id === r.item_id ? { ...x, is_low: false, dancer: null } : x)));
      res = await supabase.rpc("family_inventory_unmark_low", { p_item_id: r.item_id });
    } else {
      const dancer = pickDancer(rows, allDancers);
      setRows(xs => xs.map(x => (x.item_id === r.item_id ? { ...x, is_low: true, dancer } : x)));
      res = await supabase.rpc("family_inventory_mark_low", { p_item_id: r.item_id, p_dancer: dancer });
    }
    setBusy(null);
    if (res.error) setErr(res.error.message);
    load();
  };

  if (loading) return <div style={{ padding: _pad, color: T.slate500, fontSize: 13 }}>Loading…</div>;

  return (
    <div style={{ padding: _pad, maxWidth: 820, margin: "0 auto", boxSizing: "border-box" }}>
      <DayDoneStyles />
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 10, marginBottom: 12 }}>
        <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900 }}>{isOfficePage ? "Office" : "Inventory"}</div>
        {isOfficePage && isParent && (
          <a href="/inventory?tab=admin&place=office" style={{ fontSize: 13, color: T.blue, fontWeight: 600, textDecoration: "none" }}>
            Order office items →
          </a>
        )}
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

      {activeTab === "checklist" && (
        <Checklist rows={rows} busy={busy} onToggle={toggleLow} isParent={isParent} place={place} onAdd={() => setEditing({})} />
      )}
      {isOfficePage && (
        <OfficeRequests rows={rows} allDancers={allDancers} onChanged={load} setErr={setErr} />
      )}
      {activeTab === "admin" && isParent && (
        <>
          <div role="tablist" aria-label="Which list" style={{ display: "flex", gap: 6, marginBottom: 12 }}>
            {PLACES.map(pl => (
              <TabLink key={pl} href={placeHref(pl)} onSelect={() => setAdminPlace(pl)}
                style={{ ...btn(adminPlace === pl ? "primary" : "soft"), flex: "1 1 0", textAlign: "center", textDecoration: "none", fontSize: 14 }}>
                {PLACE_LABELS[pl]}
              </TabLink>
            ))}
          </div>
          <AdminView rows={rows} place={place} today={todayCentral()} onChanged={load} setErr={setErr} onEdit={setEditing} />
        </>
      )}
      {editing && (
        <ItemEditor item={editing} place={place} sections={[...new Set(rows.map(r => r.section).filter(Boolean))]}
          onClose={() => setEditing(null)} onSaved={load} />
      )}
    </div>
  );
}

// ─── Checklist: everyone ──────────────────────────────────────────────────
function Checklist({ rows, busy, onToggle, isParent, place, onAdd }) {
  const [q, setQ] = useState("");
  const needle = q.trim().toLowerCase();
  const shown = needle ? rows.filter(r => String(r.name || "").toLowerCase().includes(needle)) : rows;

  if (!rows.length) {
    return (
      <div style={{ ...card, textAlign: "center", padding: "28px 16px" }}>
        <div style={{ fontSize: 15, fontWeight: 600, color: T.slate900 }}>Nothing on the list yet</div>
        <div style={{ fontSize: 13, color: T.slate500, marginTop: 6 }}>
          {place === "office"
            ? (isParent ? "Add the supplies you keep stocked at the office." : "Office supplies show up here once they're added.")
            : (isParent ? "Add the things you buy to keep the house stocked." : "A parent adds the things you buy.")}
        </div>
        {isParent && <button style={{ ...btn("primary"), marginTop: 14 }} onClick={onAdd}>Add item</button>}
      </div>
    );
  }

  return (
    <div style={{ ...card, padding: "6px 10px" }}>
      {rows.length > 10 && (
        <input value={q} onChange={e => setQ(e.target.value)} placeholder="Find an item" aria-label="Find an item"
          style={{ ...input, width: "100%", margin: "6px 0 8px", fontSize: 14 }} />
      )}
      {shown.map((r, i) => {
        const newSection = i === 0 || shown[i - 1].section !== r.section;
        return (
        <Fragment key={r.item_id}>
        {newSection && <div style={sectionHead}>{r.section || "No section"}</div>}
        <div style={{ display: "flex", alignItems: "center", gap: 10, minHeight: 64, padding: "4px 8px",
          borderTop: newSection ? "none" : `1px solid ${T.slate100}`, borderRadius: 8, boxSizing: "border-box",
          background: r.is_low ? T.goldLt : "transparent" }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 15, fontWeight: 600, color: T.slate900, overflowWrap: "anywhere" }}>{r.name}</div>
            <div style={{ fontSize: 12, color: T.slate500 }}>{qtyText(r.amount, r.unit)}</div>
          </div>
          {r.is_low && (
            <div style={{ width: 56, height: 56, flexShrink: 0 }}>
              <Dancer which={r.dancer} size={56} delay={(i * 173) % 900} />
            </div>
          )}
          <button type="button" onClick={() => onToggle(r)} disabled={busy === r.item_id}
            style={{ ...btn("soft"), minHeight: 40, minWidth: 108, flexShrink: 0, opacity: busy === r.item_id ? 0.6 : 1 }}>
            {r.is_low ? "Undo" : "Running low"}
          </button>
        </div>
        </Fragment>
        );
      })}
      {needle && !shown.length && (
        <div style={{ fontSize: 13, color: T.slate500, padding: "10px 4px" }}>Nothing matches “{q.trim()}”.</div>
      )}
    </div>
  );
}

// ─── Admin: parents ───────────────────────────────────────────────────────
function AdminView({ rows, place, today, onChanged, setErr, onEdit }) {
  // Tapped items start checked; predictions start unchecked, so nothing is marked ordered by accident.
  const [on, setOn] = useState({});
  const isOn = (r) => on[r.item_id] ?? r.is_low;
  const [qty, setQty] = useState({});
  const [asking, setAsking] = useState(null);
  const [saving, setSaving] = useState(false);

  const low = rows.filter(r => r.is_low);
  const likely = rows.filter(r => !r.is_low && r.likely_out).sort((a, b) => Number(a.days_left) - Number(b.days_left));
  const picked = [...low, ...likely].filter(isOn);
  const qtyOf = (r) => qty[r.item_id] ?? num(r.suggested_qty);
  const unscheduled = rows.filter(r => r.every_days == null).length;

  const markOrdered = async () => {
    if (!picked.length || saving) return;
    const bad = picked.find(r => !(Number(qtyOf(r)) > 0));
    if (bad) { setErr(`Enter how much ${bad.name} to buy.`); return; }
    setSaving(true);
    const { error } = await supabase.rpc("family_inventory_mark_ordered", {
      p_items: picked.map(r => ({ item_id: r.item_id, qty: Number(qtyOf(r)) })),
    });
    setSaving(false);
    if (error) { setErr(error.message); return; }
    setOn({}); setQty({});
    onChanged();
  };

  const markLeft = async (r, share) => {
    setAsking(null);
    const { error } = await supabase.rpc("family_inventory_mark_left", { p_item_id: r.item_id, p_share: share });
    if (error) { setErr(error.message); return; }
    onChanged();
  };

  const orderRow = (r) => {
    const checked = isOn(r);
    const more = Number(r.suggested_qty) > Number(r.amount);
    return (
      <div key={r.item_id} style={{ padding: "10px 0", borderTop: `1px solid ${T.slate100}` }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
          <label style={{ display: "flex", alignItems: "center", gap: 8, flex: "1 1 200px", minWidth: 0, cursor: "pointer" }}>
            <input type="checkbox" checked={checked} onChange={() => setOn(s => ({ ...s, [r.item_id]: !checked }))}
              style={{ width: 20, height: 20, accentColor: T.blue, flexShrink: 0, margin: 0 }} />
            {r.is_low && <CritterIcon which={r.dancer} size={26} />}
            <span style={{ fontSize: 14, fontWeight: 600, color: checked ? T.slate900 : T.slate400, overflowWrap: "anywhere" }}>{r.name}</span>
            {!r.is_low && (
              <span style={{ fontSize: 11, fontWeight: 600, color: T.slate700, background: Number(r.days_left) <= 1 ? T.amberLt : T.slate100,
                borderRadius: 999, padding: "2px 8px", whiteSpace: "nowrap" }}>{outText(r, today)}</span>
            )}
          </label>
          <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <span style={{ fontSize: 12, color: T.slate500 }}>Buy</span>
            <input value={qtyOf(r)} inputMode="decimal" disabled={!checked} aria-label={`How much ${r.name} to buy`}
              onChange={e => setQty(x => ({ ...x, [r.item_id]: e.target.value }))}
              style={{ ...input, width: 60, textAlign: "right", opacity: checked ? 1 : 0.5 }} />
            {r.unit && <span style={{ fontSize: 12, color: T.slate700 }}>{r.unit}</span>}
            {more && <span style={{ fontSize: 11, color: T.slate500 }}>usually {num(r.amount)}</span>}
          </div>
          <button style={btn("soft", true)} onClick={() => setAsking(asking === r.item_id ? null : r.item_id)}>Still have some</button>
        </div>
        {asking === r.item_id && (
          <div style={{ display: "flex", alignItems: "center", gap: 6, flexWrap: "wrap", marginTop: 8, paddingLeft: 28 }}>
            <span style={{ fontSize: 12, color: T.slate700 }}>How much is left, next to what you usually buy?</span>
            {LEFT_CHOICES.map(([label, share]) => (
              <button key={label} style={btn("soft", true)} onClick={() => markLeft(r, share)}>{label}</button>
            ))}
          </div>
        )}
      </div>
    );
  };

  return (
    <div style={{ display: "grid", gap: 12 }}>
      {place === "home" && <MealGroceries today={today} rows={rows} onChanged={onChanged} setErr={setErr} />}
      <div style={card}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>Order this week</div>
        {!low.length && !likely.length ? (
          <div style={{ fontSize: 13, color: T.slate500, marginTop: 6 }}>Nothing to order right now.</div>
        ) : (
          <>
            {low.length > 0 && (
              <Group title="Running low" note={place === "office" ? "The team tapped or requested these." : "Someone tapped these."}>
                {low.map(orderRow)}
              </Group>
            )}
            {likely.length > 0 && (
              <Group title="Likely out" note="Nobody tapped these, but at the usual pace they run out before next week's order. Check the ones you're buying.">
                {likely.map(orderRow)}
              </Group>
            )}
            <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 12 }}>
              <button style={{ ...btn("primary"), opacity: picked.length && !saving ? 1 : 0.5 }} disabled={!picked.length || saving} onClick={markOrdered}>
                {saving ? "Saving…" : `Mark ${picked.length} ordered`}
              </button>
            </div>
          </>
        )}
      </div>

      <div style={card}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>All items{rows.length ? ` (${rows.length})` : ""}</div>
          <button style={btn("primary")} onClick={() => onEdit({})}>Add item</button>
        </div>
        {!rows.length && <div style={{ fontSize: 13, color: T.slate500, marginTop: 6 }}>Nothing on the list yet.</div>}
        {unscheduled > 0 && (
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 6 }}>
            Set how often on the items you know. The rest are learned from Running low taps and orders.
          </div>
        )}
        <div style={{ marginTop: 4 }}>
          {rows.map((r, i) => (
            <Fragment key={r.item_id}>
            {(i === 0 || rows[i - 1].section !== r.section) && <div style={{ ...sectionHead, padding: "14px 0 4px" }}>{r.section || "No section"}</div>}
            <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "9px 0", borderTop: `1px solid ${T.slate100}` }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14, fontWeight: 600, color: T.slate900, overflowWrap: "anywhere" }}>{r.name}</div>
                <div style={{ fontSize: 12, color: T.slate500 }}>
                  Buy {[qtyText(r.amount, r.unit), everyText(r.every_days)].filter(Boolean).join(" ")}.
                  {Number(r.measured) > 0 ? ` Lately it lasts ${lastsText(r.lasts_days)}.` : r.every_days == null ? " Learning from use." : ""}
                </div>
              </div>
              <button style={btn("soft", true)} onClick={() => onEdit(r)}>Edit</button>
            </div>
            </Fragment>
          ))}
        </div>
      </div>
    </div>
  );
}

function Group({ title, note, children }) {
  return (
    <div style={{ marginTop: 12 }}>
      <div style={{ fontSize: 13, fontWeight: 700, color: T.slate700 }}>{title}</div>
      {note && <div style={{ fontSize: 12, color: T.slate500, marginTop: 2, marginBottom: 4 }}>{note}</div>}
      {children}
    </div>
  );
}

// ─── Add or edit one item ─────────────────────────────────────────────────
function ItemEditor({ item, place, sections, onClose, onSaved }) {
  const isNew = !item?.item_id;
  const days0 = Number(item?.every_days);
  const hasDays0 = item?.every_days != null && Number.isFinite(days0);
  const inWeeks0 = !hasDays0 || (days0 >= 7 && days0 % 7 === 0);
  const [name, setName] = useState(item?.name || "");
  const [amount, setAmount] = useState(isNew ? "1" : num(item.amount));
  const [unit, setUnit] = useState(item?.unit || "");
  const [section, setSection] = useState(item?.section || "");
  const [every, setEvery] = useState(isNew ? "" : hasDays0 ? num(inWeeks0 ? days0 / 7 : days0) : "");
  const [per, setPer] = useState(inWeeks0 ? "weeks" : "days");
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState(null);
  const [added, setAdded] = useState(null);
  const nameRef = useRef(null);

  const everyDays = String(every).trim() === "" ? null : per === "weeks" ? Number(every) * 7 : Number(every);
  const presetChanged = !isNew && (Number(amount) !== Number(item.amount) || everyDays !== (item.every_days == null ? null : Number(item.every_days)));
  const label = { fontSize: 13, color: T.slate700, display: "grid", gap: 4 };

  const save = async (e) => {
    e.preventDefault();
    setMsg(null);
    const a = Number(amount);
    if (!name.trim()) { setMsg("Give it a name."); return; }
    if (!(a > 0)) { setMsg("Enter how much you buy."); return; }
    if (everyDays !== null && !(everyDays > 0)) { setMsg("How often has to be a number, or leave it blank."); return; }
    const row = { name: name.trim(), section: section.trim() || null, amount: a, unit: unit.trim() || null, every_days: everyDays };
    setSaving(true);
    const res = isNew
      ? await supabase.from("family_inventory_items").insert({ agency_id: AGENCY_ID, location: place === "office" ? "office" : "home", ...row })
      : await supabase.from("family_inventory_items").update(row).eq("id", item.item_id);
    setSaving(false);
    if (res.error) { setMsg(res.error.code === "23505" ? "That item is already on the list." : res.error.message); return; }
    onSaved();
    if (!isNew) { onClose(); return; }
    setAdded(row.name); setName(""); setAmount("1"); setUnit(""); setEvery(""); setPer("weeks");  // section stays for the next item
    nameRef.current?.focus();
  };

  const remove = async () => {
    if (!window.confirm(`Delete ${item.name} from the list?`)) return;
    const { error } = await supabase.from("family_inventory_items").delete().eq("id", item.item_id);
    if (error) { setMsg(error.message); return; }
    onSaved(); onClose();
  };

  return (
    <div onClick={onClose} style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.35)", zIndex: 55, display: "flex",
      alignItems: "flex-start", justifyContent: "center", overflowY: "auto", padding: 12, boxSizing: "border-box" }}>
      <form onSubmit={save} onClick={e => e.stopPropagation()} style={{ ...card, width: "100%", maxWidth: 420, margin: "auto", display: "grid", gap: 12 }}>
        <div style={{ fontSize: 17, fontWeight: 700, color: T.slate900 }}>
          {isNew ? "Add item" : "Edit item"}{place === "office" ? " · Office" : ""}
        </div>
        {added && <div style={{ fontSize: 13, color: T.green }}>Added {added}. Add the next one or tap Done.</div>}
        <label style={label}>Name
          <input ref={nameRef} autoFocus value={name} onChange={e => setName(e.target.value)} placeholder="Milk"
            style={{ ...input, width: "100%", fontSize: 14 }} />
        </label>
        <label style={label}>Section
          <input value={section} onChange={e => setSection(e.target.value)} list="inventory-sections" placeholder={place === "office" ? "SUPPLIES" : "PRODUCE"}
            style={{ ...input, width: "100%", fontSize: 14 }} />
          <datalist id="inventory-sections">{(sections || []).map(s => <option key={s} value={s} />)}</datalist>
        </label>
        <div style={label}>How much you buy
          <div style={{ display: "flex", gap: 8 }}>
            <input value={amount} onChange={e => setAmount(e.target.value)} inputMode="decimal" aria-label="How much you buy"
              style={{ ...input, width: 80, fontSize: 14 }} />
            <input value={unit} onChange={e => setUnit(e.target.value)} placeholder="gal, dozen, pack" aria-label="Unit"
              style={{ ...input, flex: 1, minWidth: 0, fontSize: 14 }} />
          </div>
        </div>
        <div style={label}>How often
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            <span style={{ fontSize: 14, color: T.slate700 }}>Every</span>
            <input value={every} onChange={e => setEvery(e.target.value)} inputMode="decimal" aria-label="How often" placeholder="?"
              style={{ ...input, width: 70, fontSize: 14 }} />
            <select value={per} onChange={e => setPer(e.target.value)} aria-label="Days or weeks" style={{ ...input, fontSize: 14 }}>
              <option value="days">days</option>
              <option value="weeks">weeks</option>
            </select>
          </div>
        </div>
        <div style={{ fontSize: 12, color: T.slate500 }}>Not sure how often? Leave it blank and the site learns it from use.</div>
        {presetChanged && <div style={{ fontSize: 12, color: T.slate500 }}>A new amount or schedule starts the learning over from it.</div>}
        {msg && <div style={{ fontSize: 13, color: T.red }}>{msg}</div>}
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
          {isNew ? <span /> : <button type="button" style={btn("danger")} onClick={remove}>Delete</button>}
          <div style={{ display: "flex", gap: 8 }}>
            <button type="button" style={btn()} onClick={onClose}>{added ? "Done" : "Cancel"}</button>
            <button type="submit" style={{ ...btn("primary"), opacity: saving ? 0.6 : 1 }} disabled={saving}>
              {saving ? "Saving…" : isNew ? "Add" : "Save"}
            </button>
          </div>
        </div>
      </form>
    </div>
  );
}

// ─── Groceries for next week's meals (Wednesday to Friday) ────────────────
// The meal plan's grocery list for the coming Saturday-to-Friday week, checked against
// this inventory by family_meal_grocery(). Items you'll need are checked; "Add to order"
// taps them Running low so they join the order above. Things not on the inventory list
// are listed to buy separately.
const GROCERY_DAYS = [3, 4, 5]; // Wednesday, Thursday, Friday
function MealGroceries({ today, rows, onChanged, setErr }) {
  const dow = new Date(utcDay(today)).getUTCDay();
  const show = GROCERY_DAYS.includes(dow);
  const [list, setList] = useState(null);
  const [off, setOff] = useState({});
  const [saving, setSaving] = useState(false);
  const [showHave, setShowHave] = useState(false);
  const { all: allDancers } = useDancers();

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("family_meal_grocery");
    if (error) setErr(error.message); else setList(Array.isArray(data) ? data : []);
  }, [setErr]);
  useEffect(() => { if (show) load(); }, [show, load, rows]);

  if (!show || !list) return null;
  const need = list.filter(r => r.status === "need" || r.status === "check");
  const onOrder = list.filter(r => r.status === "low");
  const have = list.filter(r => r.status === "have");
  const other = list.filter(r => r.status === "other");
  const isOn = (r) => off[r.item_id] === undefined ? r.status === "need" : !off[r.item_id];
  const picked = need.filter(isOn);
  const weekStart = new Date(utcDay(today) + ((6 - dow + 7) % 7 || 7) * 86400000);
  const fmt = (d) => d.toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });

  const addToOrder = async () => {
    if (!picked.length || saving) return;
    setSaving(true);
    const taken = [];
    for (const r of picked) {
      const dancer = pickDancer(rows, allDancers, taken);
      if (dancer) taken.push(dancer);
      const { error } = await supabase.rpc("family_inventory_mark_low", { p_item_id: r.item_id, p_dancer: dancer });
      if (error) { setErr(error.message); break; }
    }
    setSaving(false);
    setOff({});
    onChanged();
  };

  const line = (r, check) => (
    <div key={(r.item_id || r.name) + r.meals} style={{ padding: "9px 0", borderTop: `1px solid ${T.slate100}` }}>
      <label style={{ display: "flex", alignItems: "flex-start", gap: 8, cursor: check ? "pointer" : "default" }}>
        {check && (
          <input type="checkbox" checked={isOn(r)} onChange={() => setOff(s => ({ ...s, [r.item_id]: isOn(r) }))}
            style={{ width: 20, height: 20, accentColor: T.blue, flexShrink: 0, margin: 0 }} />
        )}
        <span style={{ minWidth: 0 }}>
          <span style={{ fontSize: 14, fontWeight: 600, color: T.slate900 }}>{r.name}</span>
          {r.status === "check" && <span style={{ fontSize: 11, color: T.slate500 }}> · not sure how much is left</span>}
          <span style={{ display: "block", fontSize: 12, color: T.slate500, overflowWrap: "anywhere" }}>{r.amounts}</span>
        </span>
      </label>
    </div>
  );

  return (
    <div style={{ ...card, borderColor: T.blue }}>
      <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>Groceries for next week's meals</div>
      <div style={{ fontSize: 13, color: T.slate500, marginTop: 2 }}>
        {fmt(weekStart)} – {fmt(new Date(weekStart.getTime() + 6 * 86400000))}, checked against what's in the house.
      </div>
      {!list.length && <div style={{ fontSize: 13, color: T.slate500, marginTop: 8 }}>No recipes on next week's plan yet.</div>}
      {need.length > 0 && (
        <Group title={`Need to buy (${need.length})`} note="Expected to run out before the meal that uses it.">
          {need.map(r => line(r, true))}
          <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 12 }}>
            <button style={{ ...btn("primary"), opacity: picked.length && !saving ? 1 : 0.5 }} disabled={!picked.length || saving} onClick={addToOrder}>
              {saving ? "Adding…" : `Add ${picked.length} to the order`}
            </button>
          </div>
        </Group>
      )}
      {other.length > 0 && (
        <Group title={`Not on the inventory list (${other.length})`} note="Buy these or check the pantry.">
          {other.map(r => line({ ...r, amounts: `${r.amounts} · ${r.meals}` }, false))}
        </Group>
      )}
      {onOrder.length > 0 && (
        <Group title={`Already on the order (${onOrder.length})`}>
          {onOrder.map(r => line(r, false))}
        </Group>
      )}
      {have.length > 0 && (
        <div style={{ marginTop: 10 }}>
          <button style={btn("soft", true)} onClick={() => setShowHave(v => !v)}>
            {showHave ? "Hide" : "Show"} {have.length} you should already have
          </button>
          {showHave && <div style={{ marginTop: 6 }}>{have.map(r => line(r, false))}</div>}
        </div>
      )}
    </div>
  );
}

// ─── Office page: snack requests and prize cart ideas ─────────────────────
// A snack request lands on the office list as Running low (new snacks are added under SNACKS),
// so Alvi sees it with the rest of the office order. Prize ideas wait until the quarter's
// prize cart close, which sends them to Alvi.
function OfficeRequests({ rows, allDancers, onChanged, setErr }) {
  const [snack, setSnack] = useState("");
  const [idea, setIdea] = useState("");
  const [link, setLink] = useState("");
  const [mine, setMine] = useState([]);
  const [saving, setSaving] = useState(null);
  const [done, setDone] = useState(null);
  const label = { fontSize: 13, color: T.slate700, display: "grid", gap: 4 };

  const loadMine = useCallback(async () => {
    const { data, error } = await supabase.rpc("prize_cart_ideas_mine");
    if (error) setErr(error.message); else setMine(Array.isArray(data) ? data : []);
  }, [setErr]);
  useEffect(() => { loadMine(); }, [loadMine]);

  const askSnack = async (e) => {
    e.preventDefault();
    if (!snack.trim() || saving) return;
    setSaving("snack"); setDone(null);
    const { error } = await supabase.rpc("office_request_snack", { p_name: snack.trim(), p_dancer: pickDancer(rows, allDancers) });
    setSaving(null);
    if (error) { setErr(error.message); return; }
    setDone(`Asked for ${snack.trim()}.`);
    setSnack("");
    onChanged();
  };

  const sendIdea = async (e) => {
    e.preventDefault();
    if (!idea.trim() || saving) return;
    setSaving("idea"); setDone(null);
    const { error } = await supabase.rpc("prize_cart_idea_add", { p_idea: idea.trim(), p_link: link.trim() || null });
    setSaving(null);
    if (error) { setErr(error.message); return; }
    setIdea(""); setLink("");
    loadMine();
  };

  const removeIdea = async (id) => {
    const { error } = await supabase.rpc("prize_cart_idea_remove", { p_id: id });
    if (error) { setErr(error.message); return; }
    loadMine();
  };

  return (
    <div style={{ display: "grid", gap: 12, marginTop: 12, gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))" }}>
      <form onSubmit={askSnack} style={{ ...card, display: "grid", gap: 10, alignContent: "start" }}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>Request a snack</div>
        <label style={label}>What would you like stocked?
          <input value={snack} onChange={e => setSnack(e.target.value)} placeholder="Trail mix" maxLength={80}
            style={{ ...input, width: "100%", fontSize: 14 }} />
        </label>
        {done && <div style={{ fontSize: 13, color: T.green }}>{done}</div>}
        <button type="submit" disabled={!snack.trim() || saving === "snack"}
          style={{ ...btn("primary"), justifySelf: "start", opacity: snack.trim() && saving !== "snack" ? 1 : 0.5 }}>
          {saving === "snack" ? "Sending…" : "Request"}
        </button>
      </form>

      <form onSubmit={sendIdea} style={{ ...card, display: "grid", gap: 10, alignContent: "start" }}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>Prize cart idea</div>
        <div style={{ fontSize: 12, color: T.slate500, marginTop: -6 }}>Goes to Alvi when the prize cart is restocked at the end of the quarter.</div>
        <label style={label}>Your idea
          <input value={idea} onChange={e => setIdea(e.target.value)} placeholder="Wireless earbuds" maxLength={200}
            style={{ ...input, width: "100%", fontSize: 14 }} />
        </label>
        <label style={label}>Link (optional)
          <input value={link} onChange={e => setLink(e.target.value)} placeholder="https://" inputMode="url"
            style={{ ...input, width: "100%", fontSize: 14 }} />
        </label>
        <button type="submit" disabled={!idea.trim() || saving === "idea"}
          style={{ ...btn("primary"), justifySelf: "start", opacity: idea.trim() && saving !== "idea" ? 1 : 0.5 }}>
          {saving === "idea" ? "Sending…" : "Send idea"}
        </button>
        {mine.length > 0 && (
          <div>
            <div style={{ fontSize: 12, fontWeight: 700, color: T.slate500, marginTop: 4 }}>Your ideas this quarter</div>
            {mine.map(m => (
              <div key={m.id} style={{ display: "flex", alignItems: "center", gap: 8, padding: "7px 0", borderTop: `1px solid ${T.slate100}` }}>
                <div style={{ flex: 1, minWidth: 0, fontSize: 13, color: T.slate900, overflowWrap: "anywhere" }}>
                  {m.link ? <a href={m.link} target="_blank" rel="noopener noreferrer" style={{ color: T.blue }}>{m.idea}</a> : m.idea}
                </div>
                <button type="button" style={btn("soft", true)} onClick={() => removeIdea(m.id)}>Remove</button>
              </div>
            ))}
          </div>
        )}
      </form>
    </div>
  );
}
