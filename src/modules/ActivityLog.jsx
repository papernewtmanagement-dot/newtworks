import { useState, useEffect, useMemo, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { T } from "../lib/theme.js";

// ============================================================
// ActivityLog — the Production module (nav label "Production", route
// /production; the old /activity route still resolves). Team capture
// for Retention Points, sales, quotes, and cancelations.
//
// ONE flat page, in Peter's order: customer block, Relationship type
// and Good Neighbor Connect, service tasks, the "Also" items,
// Canceled, Marketing type (with who sourced the lead on a referral),
// Quoted, Sold, then ECRM link and note, and one Log button.
//
// Quoted, Sold, and Canceled are lists of POLICIES, not sets of lines.
// A household can have two auto policies and a home and a boat, so
// clicking a bubble ADDS one policy of that line; click it again for a
// second. Auto and Fire policies carry a type (Private Passenger,
// Classic, GAINSCO, Home, RDP, PLUP, and so on) read from the
// product_types table, so adding a type later never touches this file.
//
// Layout follows the web-form research Peter asked for (2026-09-04):
//  * Fewer visible choices. Each policy block starts as one "Add" chip;
//    the line bubbles appear on tap (Hick 1952: decision time grows with
//    the number of options; Iyengar & Lepper 2000: too many visible
//    options lower completion).
//  * Errors after the attempt, not while typing (Bargas-Avila et al.
//    2007, Interacting with Computers: "don't show errors right away").
//    The Log button is always live; a tap with something missing shows
//    the "Still needed" list next to it and saves nothing.
//  * Sensible defaults so most rows need one tap (Johnson & Goldstein
//    2003): cars defaults to 1, date to today.
//  * Short labels, no parenthetical hints in headings, one column on a
//    phone (Seckler et al. 2014, CHI: the 20-guideline form cut
//    completion time, retries, and eye movements).
//
// The button calls rp_log_entry, which writes every part in one
// transaction. Any failure rolls the whole entry back. Only the owner
// may log on someone else's behalf, enforced server-side.
// ============================================================

const PRODUCTS = [
  { key: "auto",     label: "Auto",                 short: "Auto" },
  { key: "fire",     label: "Fire (home / renters)", short: "Fire" },
  { key: "business", label: "Business",             short: "Business" },
  { key: "life",     label: "Life",                 short: "Life" },
  { key: "health",   label: "Health",               short: "Health" },
  { key: "ips",      label: "Investment (IPS)",     short: "IPS" },
  { key: "bank",     label: "Bank",                 short: "Bank" },
];
const PRODUCT_LABEL = Object.fromEntries(PRODUCTS.map(p => [p.key, p.label]));
const PRODUCT_SHORT = Object.fromEntries(PRODUCTS.map(p => [p.key, p.short]));
const SERVICE_PREFIX = "service_task";
const RELATIONSHIPS = [
  { key: "new",      label: "New household" },
  { key: "existing", label: "Existing customer" },
  { key: "winback",  label: "Winback" },
];
const TABS = ["log", "week"];

// ---------- styles ----------
const inputBase = {
  width: "100%", padding: "10px 12px", borderRadius: 8,
  border: `1px solid ${T.slate300}`, background: T.white, color: T.slate900,
  fontSize: 15, outline: "none", boxSizing: "border-box",
};
const labelStyle = { fontSize: 12, fontWeight: 600, color: T.slate600, marginBottom: 6, display: "block" };
const hintStyle = { color: T.slate400, fontWeight: 400 };
const cardStyle = {
  background: T.white, borderRadius: 12, border: `1px solid ${T.slate200}`,
  padding: 20, boxShadow: "0 1px 2px rgba(0,0,0,0.04)",
};
const blockStyle = { marginTop: 18, paddingTop: 16, borderTop: `1px solid ${T.slate100}` };
const blockTitle = { fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 8 };
const tableTh = {
  fontSize: 11, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: 0.4,
  padding: "8px 6px", borderBottom: `1px solid ${T.slate200}`, textAlign: "left", whiteSpace: "nowrap",
};
const tableTd = { fontSize: 13, color: T.slate800, padding: "8px 6px", borderBottom: `1px solid ${T.slate100}`, verticalAlign: "top" };
const btnPrimary = (disabled) => ({
  padding: "10px 18px", borderRadius: 8, border: "none", fontWeight: 700, fontSize: 14, cursor: disabled ? "default" : "pointer",
  background: disabled ? T.slate200 : T.blue, color: disabled ? T.slate500 : T.white,
});
const btnGhost = { padding: "6px 10px", borderRadius: 6, border: `1px solid ${T.slate300}`, background: T.white, color: T.slate700, fontSize: 12, cursor: "pointer" };
const chip = (on) => ({
  padding: "8px 12px", borderRadius: 999, fontSize: 13, fontWeight: 600, cursor: "pointer", userSelect: "none",
  border: `1px solid ${on ? T.blue : T.slate300}`, background: on ? T.blueLt : T.white, color: on ? T.blue : T.slate700,
});
const chipRow = { display: "flex", flexWrap: "wrap", gap: 8 };
const gridForm = { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: 12 };
const policyRow = { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 10, padding: 12, background: T.slate50, borderRadius: 8, alignItems: "end" };
const removeBtn = { ...btnGhost, color: T.red, borderColor: T.slate300, alignSelf: "center", whiteSpace: "nowrap" };

// ---------- helpers ----------
function todayCentral() {
  return new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
}
function addDays(iso, n) {
  const [y, m, d] = iso.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d + n));
  return dt.toISOString().slice(0, 10);
}
function weekEndOf(iso) {
  const [y, m, d] = iso.split("-").map(Number);
  const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay(); // 0 = Sunday
  return addDays(iso, 6 - dow);
}
function fmtDate(iso) {
  if (!iso) return "—";
  const [y, m, d] = iso.split("-");
  return `${Number(m)}/${Number(d)}/${y}`;
}
function fmtPts(n) {
  const x = Number(n);
  return isFinite(x) ? x.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : "0.00";
}
function errText(e) {
  return e?.message || e?.error || (typeof e === "string" ? e : "Something went wrong.");
}
let _pid = 0;
const newPolicyId = () => `p${++_pid}`;

// ---------- shared field blocks ----------
function CustomerFields({ first, setFirst, initial, setInitial }) {
  const preview = first.trim() && /^[A-Za-z]$/.test(initial.trim()) ? `${first.trim()} ${initial.trim().toUpperCase()}.` : "";
  return (
    <>
      <div>
        <label style={labelStyle}>Customer first name</label>
        <input style={inputBase} value={first} onChange={e => setFirst(e.target.value)} placeholder="Anna" />
      </div>
      <div>
        <label style={labelStyle}>Last initial {preview ? <span style={hintStyle}>→ {preview}</span> : null}</label>
        <input style={inputBase} value={initial} maxLength={1} onChange={e => setInitial(e.target.value)} placeholder="S" />
      </div>
    </>
  );
}

function LogForPicker({ canLogForOthers, roster, value, onChange }) {
  if (!canLogForOthers) return null;
  return (
    <div>
      <label style={labelStyle}>Log for</label>
      <select style={inputBase} value={value || ""} onChange={e => onChange(e.target.value || null)}>
        <option value="">Myself</option>
        {(roster || []).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
      </select>
    </div>
  );
}

function Notice({ kind, children }) {
  if (!children) return null;
  const bg = kind === "error" ? T.redLt : T.greenLt;
  const fg = kind === "error" ? T.red : T.green;
  return <div style={{ padding: "10px 12px", borderRadius: 8, background: bg, color: fg, fontSize: 13, fontWeight: 600, marginTop: 12 }}>{children}</div>;
}

// The bubbles that add a policy. Until the block is used it is one
// "Add" chip, so an empty page shows three chips instead of 21 bubbles.
// Tapping Auto adds one auto policy; tapping it again adds a second.
// The count sits on the bubble.
function PolicyPicker({ list, onAdd, addLabel }) {
  const [revealed, setRevealed] = useState(false);
  const counts = {};
  for (const p of list) counts[p.line] = (counts[p.line] || 0) + 1;
  if (!revealed && list.length === 0) {
    return (
      <div style={chipRow}>
        <span style={{ ...chip(false), borderStyle: "dashed", color: T.blue }} onClick={() => setRevealed(true)}>+ {addLabel}</span>
      </div>
    );
  }
  return (
    <div style={chipRow}>
      {PRODUCTS.map(p => (
        <span key={p.key} style={chip(!!counts[p.key])} onClick={() => onAdd(p.key)}>
          {p.label}{counts[p.key] ? ` · ${counts[p.key]}` : ""}
        </span>
      ))}
    </div>
  );
}

function TypeField({ types, value, onChange, line }) {
  const opts = types[line] || [];
  if (!opts.length) return null;
  return (
    <div>
      <label style={labelStyle}>Type</label>
      <select style={inputBase} value={value || ""} onChange={e => onChange(e.target.value)}>
        <option value="">Pick one</option>
        {opts.map(t => <option key={t.type_key} value={t.type_key}>{t.label}</option>)}
      </select>
    </div>
  );
}

function typeLabel(types, line, key) {
  const t = (types[line] || []).find(x => x.type_key === key);
  return t ? t.label : null;
}

// Plain-English wrap-up of what rp_log_entry saved.
function summarizeEntry(data) {
  const parts = [];
  const a = data?.activity;
  if (a) {
    const n = (a.items || []).length;
    const pend = (a.items || []).filter(i => i.credit_available_on);
    parts.push(`${n} activity item${n === 1 ? "" : "s"} for $${fmtPts(a.points_total)}` +
      (pend.length ? ` (save clears ${fmtDate(pend[0].credit_available_on)})` : ""));
  }
  const q = data?.quote;
  if (q) parts.push(`quoted ${q.policies} polic${q.policies === 1 ? "y" : "ies"}`);
  const s = data?.sale;
  if (s) {
    const credits = (s.credits || []).map(c => c.activity_key === "multiline_sold" ? `Multiline (${PRODUCT_SHORT[c.line] || c.line})` : "Referral Sold");
    parts.push(`sold ${s.policies} polic${s.policies === 1 ? "y" : "ies"} for $${fmtPts(s.total_premium)} premium` +
      (credits.length ? `, credited ${credits.join(", ")} = $${fmtPts(s.retention_points)}` : ", no multiline or referral credit"));
  }
  const cs = Array.isArray(data?.cancelation) ? data.cancelation : [];
  if (cs.length) {
    const lines = cs.map(c => PRODUCT_SHORT[c.policy_line] || c.policy_line).join(", ");
    const voided = cs.reduce((n, c) => n + Number(c.saves_voided || 0), 0);
    parts.push(`canceled: ${lines}` + (voided > 0 ? `, ${voided} unpaid save${voided === 1 ? "" : "s"} taken back` : ""));
  }
  return `Logged for ${data?.customer || "the customer"}: ${parts.join("; ")}.`;
}

// =====================================================================
// Entry page — one customer, one contact, everything that happened, on
// one flat page. One Log button; one RPC that saves all of it or none.
// =====================================================================
function EntryPage({ values, sources, types, isOwner, roster, onLogged, refreshKey }) {
  const today = todayCentral();
  const [first, setFirst] = useState("");
  const [initial, setInitial] = useState("");
  const [date, setDate] = useState(today);
  const [logFor, setLogFor] = useState(null);
  const [relationship, setRelationship] = useState("");
  const [gnc, setGnc] = useState("");
  const [source, setSource] = useState("");
  const [sourcedBy, setSourcedBy] = useState("");
  const [checked, setChecked] = useState({});
  const [saveLine, setSaveLine] = useState("");
  const [saveReason, setSaveReason] = useState("");
  const [canceled, setCanceled] = useState([]);   // [{id, line, type}]
  const [cReason, setCReason] = useState("");
  const [quoted, setQuoted] = useState([]);       // [{id, line, type}]
  const [sold, setSold] = useState([]);           // [{id, line, type, premium, vehicles, isNewLine}]
  const [ecrm, setEcrm] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");
  const [attempted, setAttempted] = useState(false); // show what's missing only after a Log tap
  const [formKey, setFormKey] = useState(0);         // bumps on reset so the Add chips fold back up

  const serviceTasks = (values || []).filter(v => v.category === "logged" && v.activity_key.startsWith(SERVICE_PREFIX));
  const alsoItems = (values || []).filter(v => v.category === "logged" && !v.activity_key.startsWith(SERVICE_PREFIX));
  const byKey = useMemo(() => Object.fromEntries((values || []).map(v => [v.activity_key, v])), [values]);

  const toggleChecked = (k) => setChecked(c => ({ ...c, [k]: !c[k] }));
  const addPolicy = (setter, extra) => (line) => setter(list => [...list, { id: newPolicyId(), line, type: "", ...extra }]);
  const editPolicy = (setter) => (id, field, val) => setter(list => list.map(p => p.id === id ? { ...p, [field]: val } : p));
  const dropPolicy = (setter) => (id) => setter(list => list.filter(p => p.id !== id));

  const addCanceled = addPolicy(setCanceled, { premium: "", vehicles: "1" });
  const addQuoted = addPolicy(setQuoted, {});
  const addSold = addPolicy(setSold, { premium: "", vehicles: "1", isNewLine: true });
  const editSold = editPolicy(setSold);
  const editCanceled = editPolicy(setCanceled);

  // ---- what is in the entry right now ----
  const activityItems = [];
  for (const k of Object.keys(checked)) {
    if (!checked[k] || !byKey[k]) continue;
    if (k === "cancelation_saved") activityItems.push({ activity_key: k, save_line: saveLine, save_reason: saveReason.trim() });
    else activityItems.push({ activity_key: k });
  }
  const activityTotal = activityItems.reduce((s, it) => s + Number(byKey[it.activity_key]?.points || 0), 0);
  const saleTotal = sold.reduce((s, p) => s + (Number(p.premium) || 0), 0);

  const hasActivity = activityItems.length > 0;
  const hasCxl = canceled.length > 0;
  const hasQuote = quoted.length > 0;
  const hasSale = sold.length > 0;
  const hasAnything = hasActivity || hasCxl || hasQuote || hasSale;
  const customerOk = !!first.trim() && /^[A-Za-z]$/.test(initial.trim());
  const isReferral = source === "referral";
  const householdFresh = relationship === "new" || relationship === "winback";
  const needsType = (line) => (types[line] || []).length > 0;
  const missingType = (list) => list.some(p => needsType(p.line) && !p.type);

  // ---- what still needs fixing, in plain words (mirrors the server rules) ----
  const problems = [];
  if (!customerOk) problems.push("Customer first name and last initial.");
  if (!hasAnything) problems.push("Add what happened: a service task, a cancelation, a quote, or a sale.");
  if ((hasActivity || hasQuote) && date < addDays(today, -7)) problems.push("Activity and quotes are logged within 7 days. Pick a later date or split the entry.");
  if (hasSale && date < addDays(today, -30)) problems.push("A sale is logged within 30 days of the bind.");
  if (hasCxl && date < addDays(today, -90)) problems.push("A cancelation is logged within 90 days.");
  if (checked.cancelation_saved) {
    if (date !== today) problems.push("A save is logged the same business day it comes in. Set the date to today.");
    if (!saveLine || !saveReason.trim()) problems.push("The save needs the policy line at risk and the reason the customer gave.");
  }
  if (checked.policy_review && !note.trim()) problems.push("The policy review needs a note on what you covered.");
  if (missingType(canceled)) problems.push("Every canceled policy needs its type.");
  if (canceled.some(p => p.premium === "" || !(Number(p.premium) >= 0))) problems.push("Every canceled policy needs its premium.");
  if (canceled.some(p => p.line === "auto" && !(Number(p.vehicles) >= 1))) problems.push("Every canceled auto policy needs its number of cars.");
  if (missingType(quoted)) problems.push("Every quoted policy needs its type.");
  if (missingType(sold)) problems.push("Every sold policy needs its type.");
  if (hasSale) {
    if (!relationship) problems.push("A sale needs the relationship type.");
    if (!source) problems.push("A sale needs the marketing type.");
    if (gnc === "") problems.push("A sale needs to say whether Good Neighbor Connect was used.");
    if (!ecrm.trim()) problems.push("A sale needs the ECRM opportunity link.");
    if (sold.some(p => p.premium === "" || !(Number(p.premium) >= 0))) problems.push("Every sold policy needs its premium.");
    if (sold.some(p => p.line === "auto" && !(Number(p.vehicles) >= 1))) problems.push("Every sold auto policy needs its number of cars.");
  }
  if (hasSale && hasCxl) {
    const soldLines = new Set(sold.map(p => p.line));
    const clash = [...new Set(canceled.filter(p => soldLines.has(p.line)).map(p => p.line))];
    if (clash.length) problems.push(`${clash.map(k => PRODUCT_SHORT[k]).join(", ")} is both sold and canceled in this entry. Log those as two entries.`);
  }
  if (ecrm.trim() && !/^https?:\/\//i.test(ecrm.trim())) problems.push("The ECRM link must start with http.");
  const canSubmit = !busy;

  const reset = () => {
    setFirst(""); setInitial(""); setDate(today);
    setRelationship(""); setGnc(""); setSource(""); setSourcedBy("");
    setChecked({}); setSaveLine(""); setSaveReason("");
    setCanceled([]); setCReason(""); setQuoted([]); setSold([]);
    setEcrm(""); setNote("");
    setAttempted(false); setFormKey(k => k + 1);
  };

  const submit = async () => {
    setErr(""); setOk("");
    setAttempted(true);
    if (busy || problems.length > 0) return;
    setBusy(true);
    try {
      const payload = {
        customer_first: first.trim(), customer_last_initial: initial.trim(), occurred_on: date,
        ecrm_url: ecrm.trim() || null, note: note.trim() || null, team_member_id: logFor,
        relationship_type: relationship || null,
        gnc_used: gnc === "" ? null : gnc === "yes",
        marketing_source: source || null,
        sourced_by_team_member_id: isReferral && sourcedBy ? sourcedBy : null,
        activity: hasActivity ? { items: activityItems } : null,
        cancelation: hasCxl ? {
          items: canceled.map(p => ({
            line_of_business: p.line, product_type: p.type || null,
            premium: Number(p.premium), vehicle_count: p.line === "auto" ? Number(p.vehicles) : null,
          })),
          reason: cReason.trim() || null,
        } : null,
        quote: hasQuote ? { items: quoted.map(p => ({ line_of_business: p.line, product_type: p.type || null })) } : null,
        sale: hasSale ? {
          products: sold.map(p => ({
            line_of_business: p.line, product_type: p.type || null,
            premium: Number(p.premium),
            policy_count: 1,
            vehicle_count: p.line === "auto" ? Number(p.vehicles) : null,
            is_new_line: householdFresh ? true : !!p.isNewLine,
          })),
        } : null,
      };
      const { data, error } = await supabase.rpc("rp_log_entry", { p_payload: payload });
      if (error) { setErr(errText(error)); return; }
      if (!data?.ok) { setErr(errText(data)); return; }
      setOk(summarizeEntry(data));
      reset();
      onLogged?.();
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  };

  const selectedTasks = serviceTasks.filter(v => checked[v.activity_key]);

  return (
    <div>
      <div style={cardStyle}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>What happened with this customer?</div>
        <div style={{ fontSize: 13, color: T.slate500, marginBottom: 16 }}>Tap what happened. Skip what didn't. One button saves it all.</div>

        <div style={gridForm}>
          <CustomerFields first={first} setFirst={setFirst} initial={initial} setInitial={setInitial} />
          <div>
            <label style={labelStyle}>Date</label>
            <input type="date" style={inputBase} value={date} max={today} min={addDays(today, -90)} onChange={e => setDate(e.target.value)} />
          </div>
          <LogForPicker canLogForOthers={isOwner} roster={roster} value={logFor} onChange={setLogFor} />
        </div>

        <div style={{ ...gridForm, marginTop: 12 }}>
          <div>
            <label style={labelStyle}>Relationship type</label>
            <select style={inputBase} value={relationship} onChange={e => setRelationship(e.target.value)}>
              <option value="">Pick one</option>
              {RELATIONSHIPS.map(r => <option key={r.key} value={r.key}>{r.label}</option>)}
            </select>
          </div>
          <div>
            <label style={labelStyle}>Good Neighbor Connect used?</label>
            <select style={inputBase} value={gnc} onChange={e => setGnc(e.target.value)}>
              <option value="">Pick one</option>
              <option value="yes">Yes</option>
              <option value="no">No</option>
            </select>
          </div>
        </div>

        {/* ---- service tasks ---- */}
        <div style={blockStyle}>
          <div style={blockTitle}>Service tasks</div>
          <div style={chipRow}>
            {serviceTasks.map(v => (
              <span key={v.activity_key} style={chip(!!checked[v.activity_key])} onClick={() => toggleChecked(v.activity_key)}>
                {v.label} · ${fmtPts(v.points)}
              </span>
            ))}
            {serviceTasks.length === 0 && <span style={{ fontSize: 12, color: T.slate500 }}>No service tasks are set up.</span>}
          </div>
          {selectedTasks.length > 0 && (
            <div style={{ fontSize: 12, color: T.slate500, marginTop: 8, lineHeight: 1.5 }}>
              {selectedTasks.map(v => <div key={v.activity_key}><strong style={{ color: T.slate700 }}>{v.label}.</strong> {v.description}</div>)}
            </div>
          )}
        </div>

        {/* ---- also ---- */}
        <div style={blockStyle}>
          <div style={blockTitle}>Also</div>
          <div style={chipRow}>
            {alsoItems.map(v => (
              <span key={v.activity_key} style={chip(!!checked[v.activity_key])} onClick={() => toggleChecked(v.activity_key)}>
                {v.label} · ${fmtPts(v.points)}
              </span>
            ))}
          </div>
          {checked.cancelation_saved && (
            <div style={{ ...gridForm, marginTop: 12, padding: 12, background: T.slate50, borderRadius: 8 }}>
              <div>
                <label style={labelStyle}>Policy line at risk</label>
                <select style={inputBase} value={saveLine} onChange={e => setSaveLine(e.target.value)}>
                  <option value="">Pick one</option>
                  {PRODUCTS.map(p => <option key={p.key} value={p.key}>{p.label}</option>)}
                </select>
              </div>
              <div style={{ gridColumn: "1 / -1" }}>
                <label style={labelStyle}>Reason the customer gave</label>
                <input style={inputBase} value={saveReason} onChange={e => setSaveReason(e.target.value)} placeholder="Rate went up at renewal; found a cheaper quote" />
                <div style={{ fontSize: 12, color: T.slate500, marginTop: 6 }}>Logged the same business day. Credit lands the week the 30-day hold clears, as long as the policy is still active.</div>
              </div>
            </div>
          )}
        </div>

        {/* ---- canceled ---- */}
        <div style={blockStyle}>
          <div style={blockTitle}>Canceled</div>
          <PolicyPicker key={`c${formKey}`} list={canceled} onAdd={addCanceled} addLabel="Add a canceled policy" />
          {canceled.length > 0 && (
            <div style={{ marginTop: 12, display: "grid", gap: 10 }}>
              {canceled.map(p => (
                <div key={p.id} style={policyRow}>
                  <div style={{ fontWeight: 700, color: T.slate800, alignSelf: "center" }}>{PRODUCT_LABEL[p.line]}</div>
                  <TypeField types={types} line={p.line} value={p.type} onChange={v => editCanceled(p.id, "type", v)} />
                  <div>
                    <label style={labelStyle}>Premium</label>
                    <input type="number" inputMode="decimal" min="0" step="0.01" style={inputBase} value={p.premium} onChange={e => editCanceled(p.id, "premium", e.target.value)} placeholder="0.00" />
                  </div>
                  {p.line === "auto" && (
                    <div>
                      <label style={labelStyle}>Cars</label>
                      <input type="number" inputMode="numeric" min="1" step="1" style={inputBase} value={p.vehicles} onChange={e => editCanceled(p.id, "vehicles", e.target.value)} />
                    </div>
                  )}
                  <button type="button" style={removeBtn} onClick={() => dropPolicy(setCanceled)(p.id)}>Remove</button>
                </div>
              ))}
              <div>
                <label style={labelStyle}>Reason <span style={hintStyle}>(optional)</span></label>
                <input style={inputBase} value={cReason} onChange={e => setCReason(e.target.value)} placeholder="what they told us" />
                <div style={{ fontSize: 12, color: T.slate500, marginTop: 6 }}>If someone logged a save on this customer and line and that credit has not been paid yet, this takes it back.</div>
              </div>
            </div>
          )}
        </div>

        {/* ---- marketing type ---- */}
        <div style={blockStyle}>
          <div style={gridForm}>
            <div>
              <label style={labelStyle}>Marketing type</label>
              <select style={inputBase} value={source} onChange={e => setSource(e.target.value)}>
                <option value="">Pick one</option>
                {(sources || []).map(s => <option key={s.source_key} value={s.source_key}>{s.label}</option>)}
              </select>
            </div>
            {isReferral && (
              <div>
                <label style={labelStyle}>Who sourced the lead?</label>
                <select style={inputBase} value={sourcedBy} onChange={e => setSourcedBy(e.target.value)}>
                  <option value="">{logFor ? "The person logged for" : "Me"}</option>
                  {(roster || []).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
                </select>
              </div>
            )}
          </div>
        </div>

        {/* ---- quoted ---- */}
        <div style={blockStyle}>
          <div style={blockTitle}>Quoted</div>
          <PolicyPicker key={`q${formKey}`} list={quoted} onAdd={addQuoted} addLabel="Add a quoted policy" />
          {quoted.length > 0 && (
            <div style={{ marginTop: 12, display: "grid", gap: 10 }}>
              {quoted.map(p => (
                <div key={p.id} style={policyRow}>
                  <div style={{ fontWeight: 700, color: T.slate800, alignSelf: "center" }}>{PRODUCT_LABEL[p.line]}</div>
                  <TypeField types={types} line={p.line} value={p.type} onChange={v => editPolicy(setQuoted)(p.id, "type", v)} />
                  <button type="button" style={removeBtn} onClick={() => dropPolicy(setQuoted)(p.id)}>Remove</button>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* ---- sold ---- */}
        <div style={blockStyle}>
          <div style={blockTitle}>Sold</div>
          <PolicyPicker key={`s${formKey}`} list={sold} onAdd={addSold} addLabel="Add a sold policy" />
          {sold.length > 0 && (
            <div style={{ marginTop: 12, display: "grid", gap: 10 }}>
              {sold.map(p => (
                <div key={p.id} style={policyRow}>
                  <div style={{ fontWeight: 700, color: T.slate800, alignSelf: "center" }}>{PRODUCT_LABEL[p.line]}</div>
                  <TypeField types={types} line={p.line} value={p.type} onChange={v => editSold(p.id, "type", v)} />
                  <div>
                    <label style={labelStyle}>Premium</label>
                    <input type="number" inputMode="decimal" min="0" step="0.01" style={inputBase} value={p.premium} onChange={e => editSold(p.id, "premium", e.target.value)} placeholder="0.00" />
                  </div>
                  {p.line === "auto" && (
                    <div>
                      <label style={labelStyle}>Cars</label>
                      <input type="number" inputMode="numeric" min="1" step="1" style={inputBase} value={p.vehicles} onChange={e => editSold(p.id, "vehicles", e.target.value)} />
                    </div>
                  )}
                  {relationship === "existing" && (
                    <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: T.slate700, paddingBottom: 10 }}>
                      <input type="checkbox" checked={!!p.isNewLine} onChange={e => editSold(p.id, "isNewLine", e.target.checked)} />
                      New line
                    </label>
                  )}
                  <button type="button" style={removeBtn} onClick={() => dropPolicy(setSold)(p.id)}>Remove</button>
                </div>
              ))}
              <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "baseline" }}>
                <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>Total premium: ${fmtPts(saleTotal)}</div>
                <span style={{ fontSize: 12, color: T.slate500 }}>
                  Multiline pays once per line. Two auto policies is still one auto line for the household.
                </span>
              </div>
            </div>
          )}
        </div>

        {/* ---- ECRM + note ---- */}
        <div style={{ ...gridForm, ...blockStyle }}>
          <div style={{ gridColumn: "1 / -1" }}>
            <label style={labelStyle}>ECRM link {hasSale ? <span style={{ color: T.red }}>(required for a sale)</span> : <span style={hintStyle}>(optional)</span>}</label>
            <input style={inputBase} value={ecrm} onChange={e => setEcrm(e.target.value)} placeholder="https://…" />
          </div>
          <div style={{ gridColumn: "1 / -1" }}>
            <label style={labelStyle}>Note {checked.policy_review ? <span style={{ color: T.red }}>(what you covered, required for a policy review)</span> : <span style={hintStyle}>(optional)</span>}</label>
            <input style={inputBase} value={note} onChange={e => setNote(e.target.value)} placeholder="Reviewed liability limits and umbrella; added rental reimbursement" />
          </div>
        </div>

        <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", marginTop: 18 }}>
          <button style={btnPrimary(!canSubmit)} disabled={!canSubmit} onClick={submit}>{busy ? "Saving…" : `Log it${activityTotal ? ` · $${fmtPts(activityTotal)}` : ""}`}</button>
        </div>
        {attempted && problems.length > 0 && (
          <div style={{ marginTop: 12, fontSize: 12, color: T.slate600, lineHeight: 1.6 }}>
            <div style={{ fontWeight: 700, color: T.slate700 }}>Still needed</div>
            {problems.map((p, i) => <div key={i}>· {p}</div>)}
          </div>
        )}
        <Notice kind="error">{err}</Notice>
        <Notice kind="ok">{ok}</Notice>
      </div>
      <PendingSaves refreshKey={refreshKey} />
    </div>
  );
}

// =====================================================================
// Saves still waiting to clear — read-only list under the entry page
// =====================================================================
function PendingSaves({ refreshKey }) {
  const [rows, setRows] = useState([]);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data } = await supabase
        .from("rp_saves_clearing_soon")
        .select("id, team_member_id, first_name, customer_label, save_line, occurred_on, credit_available_on, days_until_clear, points")
        .eq("agency_id", AGENCY_ID)
        .order("credit_available_on");
      if (alive) setRows(Array.isArray(data) ? data : []);
    })();
    return () => { alive = false; };
  }, [refreshKey]);

  if (!(rows || []).length) return null;

  return (
    <div style={{ ...cardStyle, marginTop: 16 }}>
      <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>Saves still waiting to clear</div>
      <div style={{ fontSize: 13, color: T.slate500, marginBottom: 14 }}>
        A save pays once the policy has stayed active 30 days. If one of these canceled anyway, log the cancelation above and the credit comes off before it is ever paid.
      </div>
      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead>
            <tr>
              <th style={tableTh}>Who</th>
              <th style={tableTh}>Customer</th>
              <th style={tableTh}>Line</th>
              <th style={tableTh}>Saved</th>
              <th style={tableTh}>Clears</th>
              <th style={tableTh}>Days left</th>
              <th style={tableTh}>Points</th>
            </tr>
          </thead>
          <tbody>
            {(rows || []).map(r => (
              <tr key={r.id}>
                <td style={tableTd}>{r.first_name || "\u2014"}</td>
                <td style={tableTd}>{r.customer_label}</td>
                <td style={tableTd}>{PRODUCT_LABEL[r.save_line] || r.save_line}</td>
                <td style={tableTd}>{fmtDate(r.occurred_on)}</td>
                <td style={tableTd}>{fmtDate(r.credit_available_on)}</td>
                <td style={tableTd}>{r.days_until_clear}</td>
                <td style={tableTd}>{fmtPts(r.points)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// =====================================================================
// Week view — points table + this week's entries
// =====================================================================
function WeekView({ isAdmin, myTeamId, roster, values, refreshKey }) {
  const [weekEnd, setWeekEnd, weekHref] = useTabParam("week", weekEndOf(todayCentral()));
  const [rows, setRows] = useState([]);
  const [acts, setActs] = useState([]);
  const [sales, setSales] = useState([]);
  const [quotes, setQuotes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");

  const nameOf = useMemo(() => {
    const m = new Map();
    for (const t of roster || []) m.set(t.id, t.first_name);
    return (id) => m.get(id) || "—";
  }, [roster]);
  const labelOf = useMemo(() => Object.fromEntries((values || []).map(v => [v.activity_key, v.label])), [values]);
  const safeWeek = /^\d{4}-\d{2}-\d{2}$/.test(weekEnd || "") ? weekEnd : weekEndOf(todayCentral());
  const weekStart = addDays(safeWeek, -6);

  const load = useCallback(async () => {
    setLoading(true); setErr("");
    try {
      const [p, a, s, q] = await Promise.all([
        supabase.rpc("compute_weekly_retention_points", { p_agency_id: AGENCY_ID, p_week_end_date: safeWeek }),
        supabase.from("retention_activity_log").select("id, team_member_id, activity_key, occurred_on, credited_week_end_date, credit_available_on, customer_label, note, save_reason, save_line, points, status, source, created_at")
          .eq("agency_id", AGENCY_ID).eq("status", "credited").or(`week_end_date.eq.${safeWeek},credited_week_end_date.eq.${safeWeek}`).order("occurred_on", { ascending: false }),
        supabase.from("sales_log").select("id, team_member_id, sourced_by_team_member_id, sale_date, customer_label, household_status, marketing_source, gnc_used, vehicle_count, total_premium, status, created_at, sales_log_products(line_of_business, premium, policy_count, is_new_line)")
          .eq("agency_id", AGENCY_ID).eq("status", "active").eq("week_end_date", safeWeek).order("sale_date", { ascending: false }),
        supabase.from("quote_log").select("id, team_member_id, quote_date, customer_label, is_existing_customer, products_discussed, status, created_at")
          .eq("agency_id", AGENCY_ID).eq("status", "active").eq("week_end_date", safeWeek).order("quote_date", { ascending: false }),
      ]);
      if (p.error) throw p.error;
      setRows(Array.isArray(p.data) ? p.data : []);
      setActs(Array.isArray(a.data) ? a.data : []);
      setSales(Array.isArray(s.data) ? s.data : []);
      setQuotes(Array.isArray(q.data) ? q.data : []);
    } catch (e) { setErr(errText(e)); } finally { setLoading(false); }
  }, [safeWeek]);

  useEffect(() => { load(); }, [load, refreshKey]);

  const mine = (r) => isAdmin || r.team_member_id === myTeamId;
  const visibleRows = rows.filter(mine);
  const teamNet = rows.reduce((s, r) => s + Number(r.net_points || 0), 0);
  const myActs = acts.filter(mine);
  const mySales = sales.filter(r => isAdmin || r.team_member_id === myTeamId || r.sourced_by_team_member_id === myTeamId);
  const myQuotes = quotes.filter(mine);

  const voidRow = async (fn, id, what) => {
    if (!window.confirm(`Remove this ${what}?`)) return;
    const { data, error } = await supabase.rpc(fn, { p_id: id, p_reason: null });
    if (error || !data?.ok) { window.alert(errText(error || data)); return; }
    load();
  };

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <div style={{ ...cardStyle, display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between" }}>
        <div>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>Week of {fmtDate(weekStart)} – {fmtDate(safeWeek)}</div>
          <div style={{ fontSize: 12, color: T.slate500 }}>Sunday through Saturday. Hours and calls come from the systems; the rest from what was logged.</div>
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          <TabLink href={weekHref(addDays(safeWeek, -7))} onSelect={() => setWeekEnd(addDays(safeWeek, -7))} style={btnGhost}>← Prior week</TabLink>
          <TabLink href={weekHref(weekEndOf(todayCentral()))} onSelect={() => setWeekEnd(weekEndOf(todayCentral()))} style={btnGhost}>This week</TabLink>
          <TabLink href={weekHref(addDays(safeWeek, 7))} onSelect={() => setWeekEnd(addDays(safeWeek, 7))} style={btnGhost} disabled={safeWeek >= weekEndOf(todayCentral())}>Next week →</TabLink>
        </div>
      </div>

      {err && <Notice kind="error">{err}</Notice>}

      <div style={cardStyle}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>Retention Points {loading ? <span style={{ color: T.slate400, fontWeight: 400 }}>· loading…</span> : null}</div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr>
              <th style={tableTh}>Who</th><th style={tableTh}>Hours in office</th><th style={tableTh}>Calls answered</th><th style={tableTh}>Team missed %</th>
              <th style={tableTh}>Logged</th><th style={tableTh}>From sales</th><th style={tableTh}>Gross</th><th style={tableTh}>Reduction</th><th style={tableTh}>Net points</th>
            </tr></thead>
            <tbody>
              {visibleRows.map(r => (
                <tr key={r.team_member_id}>
                  <td style={tableTd}><strong>{r.first_name}</strong> <span style={{ color: T.slate400, fontSize: 11 }}>{r.role_category}</span></td>
                  <td style={tableTd}>{fmtPts(r.hours_in_office)} <span style={{ color: T.slate400 }}>(${fmtPts(r.hour_points)})</span></td>
                  <td style={tableTd}>{r.calls_answered} <span style={{ color: T.slate400 }}>(${fmtPts(r.call_points)})</span></td>
                  <td style={tableTd}>{fmtPts(r.missed_pct)}%</td>
                  <td style={tableTd}>${fmtPts(r.logged_points)}</td>
                  <td style={tableTd}>${fmtPts(r.derived_points)}</td>
                  <td style={tableTd}>${fmtPts(r.gross_points)}</td>
                  <td style={tableTd}>{fmtPts(r.reduction_pct)}%</td>
                  <td style={{ ...tableTd, fontWeight: 700, color: T.slate900 }}>${fmtPts(r.net_points)}</td>
                </tr>
              ))}
              {!loading && visibleRows.length === 0 && <tr><td style={tableTd} colSpan={9}>Nothing to show for this week yet.</td></tr>}
            </tbody>
          </table>
        </div>
        <div style={{ fontSize: 12, color: T.slate500, marginTop: 8 }}>Team total: <strong style={{ color: T.slate800 }}>${fmtPts(teamNet)}</strong> net points. One point = one dollar.</div>
        {rows[0]?.detail && (
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>
            Team missed {Number(rows[0].detail.team_missed_calls || 0)} of {Number(rows[0].detail.team_calls_answered || 0) + Number(rows[0].detail.team_missed_calls || 0)} calls. The phone rings everyone, so a call nobody picked up — hung up or left a voicemail — counts against the whole team.
          </div>
        )}
      </div>

      <div style={cardStyle}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>Logged this week</div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr><th style={tableTh}>Date</th>{isAdmin && <th style={tableTh}>Who</th>}<th style={tableTh}>What</th><th style={tableTh}>Customer</th><th style={tableTh}>Note</th><th style={tableTh}>Points</th><th style={tableTh}></th></tr></thead>
            <tbody>
              {myActs.map(r => (
                <tr key={r.id}>
                  <td style={tableTd}>{fmtDate(r.occurred_on)}</td>
                  {isAdmin && <td style={tableTd}>{nameOf(r.team_member_id)}</td>}
                  <td style={tableTd}>{labelOf[r.activity_key] || r.activity_key}{r.credit_available_on ? <div style={{ fontSize: 11, color: T.amber }}>clears {fmtDate(r.credit_available_on)}</div> : null}</td>
                  <td style={tableTd}>{r.customer_label || "—"}</td>
                  <td style={{ ...tableTd, maxWidth: 320 }}>{r.save_reason ? `${PRODUCT_LABEL[r.save_line] || r.save_line}: ${r.save_reason}` : (r.note || "—")}</td>
                  <td style={tableTd}>${fmtPts(r.points)}</td>
                  <td style={tableTd}>{r.source === "manual" ? <button style={btnGhost} onClick={() => voidRow("rp_void_activity", r.id, "entry")}>Remove</button> : <span style={{ fontSize: 11, color: T.slate400 }}>from sale</span>}</td>
                </tr>
              ))}
              {!loading && myActs.length === 0 && <tr><td style={tableTd} colSpan={isAdmin ? 7 : 6}>Nothing logged yet this week.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      <div style={cardStyle}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>Sales this week</div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr><th style={tableTh}>Date</th><th style={tableTh}>Who</th><th style={tableTh}>Customer</th><th style={tableTh}>Household</th><th style={tableTh}>Products</th><th style={tableTh}>Cars</th><th style={tableTh}>Premium</th><th style={tableTh}>Source</th><th style={tableTh}>GNC</th><th style={tableTh}></th></tr></thead>
            <tbody>
              {mySales.map(r => (
                <tr key={r.id}>
                  <td style={tableTd}>{fmtDate(r.sale_date)}</td>
                  <td style={tableTd}>{nameOf(r.team_member_id)}{r.sourced_by_team_member_id !== r.team_member_id ? <div style={{ fontSize: 11, color: T.slate400 }}>sourced by {nameOf(r.sourced_by_team_member_id)}</div> : null}</td>
                  <td style={tableTd}>{r.customer_label}</td>
                  <td style={tableTd}>{r.household_status === "new" ? "New" : r.household_status === "winback" ? "Winback" : "Existing"}</td>
                  <td style={tableTd}>{(r.sales_log_products || []).map(p => `${PRODUCT_LABEL[p.line_of_business] || p.line_of_business} $${fmtPts(p.premium)}`).join(", ")}</td>
                  <td style={tableTd}>{r.vehicle_count ?? "—"}</td>
                  <td style={tableTd}>${fmtPts(r.total_premium)}</td>
                  <td style={tableTd}>{r.marketing_source}</td>
                  <td style={tableTd}>{r.gnc_used ? "Yes" : "No"}</td>
                  <td style={tableTd}><button style={btnGhost} onClick={() => voidRow("rp_void_sale", r.id, "sale")}>Remove</button></td>
                </tr>
              ))}
              {!loading && mySales.length === 0 && <tr><td style={tableTd} colSpan={10}>No sales logged this week.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      <div style={cardStyle}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>Quotes this week <span style={{ color: T.slate400, fontWeight: 400 }}>· {myQuotes.length}</span></div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr><th style={tableTh}>Date</th>{isAdmin && <th style={tableTh}>Who</th>}<th style={tableTh}>Customer</th><th style={tableTh}>Products discussed</th><th style={tableTh}></th></tr></thead>
            <tbody>
              {myQuotes.map(r => (
                <tr key={r.id}>
                  <td style={tableTd}>{fmtDate(r.quote_date)}</td>
                  {isAdmin && <td style={tableTd}>{nameOf(r.team_member_id)}</td>}
                  <td style={tableTd}>{r.customer_label}{r.is_existing_customer ? <span style={{ fontSize: 11, color: T.slate400 }}> · existing</span> : null}</td>
                  <td style={tableTd}>{(r.products_discussed || []).map(k => PRODUCT_LABEL[k] || k).join(", ")}</td>
                  <td style={tableTd}><button style={btnGhost} onClick={() => voidRow("rp_void_quote", r.id, "quote")}>Remove</button></td>
                </tr>
              ))}
              {!loading && myQuotes.length === 0 && <tr><td style={tableTd} colSpan={isAdmin ? 5 : 4}>No quotes logged this week.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

// =====================================================================
// Module shell
// =====================================================================
export default function ActivityLog({ userRole }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const [tab, setTab, tabHref] = useTabParam("tab", "log", TABS);
  const [values, setValues] = useState([]);
  const [sources, setSources] = useState([]);
  const [types, setTypes] = useState({});
  const [roster, setRoster] = useState([]);
  const [myTeamId, setMyTeamId] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const isAdmin = ["owner", "manager"].includes(userRole);
  // Logging on someone else's behalf is the owner's alone. The server enforces
  // it too (rp_resolve_actor), so hiding the picker is not the only thing
  // stopping it. isAdmin still governs seeing the whole team's week.
  const isOwner = userRole === "owner";

  useEffect(() => {
    let alive = true;
    (async () => {
      const [v, s, pt, r, me] = await Promise.all([
        supabase.from("retention_point_values").select("activity_key, label, points, category, requires_note, sort_order, description").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("sales_marketing_sources").select("source_key, label, sort_order").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("product_types").select("line_of_business, type_key, label, sort_order").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("team_directory").select("id, first_name, role_category, is_admin_backoffice, is_test_user, archived_at, category").eq("agency_id", AGENCY_ID).eq("is_active", true).order("first_name"),
        supabase.rpc("current_team_member_id"),
      ]);
      if (!alive) return;
      setValues(Array.isArray(v.data) ? v.data : []);
      setSources(Array.isArray(s.data) ? s.data : []);
      // types under each line, e.g. { auto: [Private Passenger, Classic, ...] }.
      // A line with no rows logs as the line itself.
      const grouped = {};
      for (const t of (Array.isArray(pt.data) ? pt.data : [])) {
        (grouped[t.line_of_business] = grouped[t.line_of_business] || []).push(t);
      }
      setTypes(grouped);
      setRoster((Array.isArray(r.data) ? r.data : []).filter(t => !t.archived_at && !t.is_test_user && !t.is_admin_backoffice && t.category === "agency"));
      setMyTeamId(me?.data || null);
    })();
    return () => { alive = false; };
  }, []);

  const bump = () => setRefreshKey(k => k + 1);
  const tabs = [
    { id: "log", label: "Log" },
    { id: "week", label: "My week" },
  ];

  return (
    <div style={{ padding: _pad, display: "grid", gap: 16 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", justifyContent: "space-between" }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 800, color: T.slate900 }}>Production</div>
          <div style={{ fontSize: 13, color: T.slate500 }}>What you wrote, quoted, kept, and lost. Logged as it happens.</div>
        </div>
      </div>
      <div style={{ display: "flex", gap: 6, overflowX: "auto", whiteSpace: "nowrap", borderBottom: `1px solid ${T.slate200}`, paddingBottom: 6 }}>
        {tabs.map(t => (
          <TabLink key={t.id} href={tabHref(t.id)} onSelect={() => setTab(t.id)} style={{
            flexShrink: 0, padding: "8px 14px", borderRadius: 8, fontSize: 13, fontWeight: 700, textDecoration: "none",
            background: tab === t.id ? T.blueLt : "transparent", color: tab === t.id ? T.blue : T.slate600,
          }}>{t.label}</TabLink>
        ))}
      </div>

      {tab === "log"  && <EntryPage values={values} sources={sources} types={types} isOwner={isOwner} roster={roster} onLogged={bump} refreshKey={refreshKey} />}
      {tab === "week" && <WeekView isAdmin={isAdmin} myTeamId={myTeamId} roster={roster} values={values} refreshKey={refreshKey} />}
    </div>
  );
}
