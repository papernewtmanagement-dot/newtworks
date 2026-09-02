import { useState, useEffect, useMemo, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { T } from "../lib/theme.js";

// ============================================================
// ActivityLog — team capture for Retention Points, sales, quotes,
// and cancellations.
//
// ONE entry page. A customer block on top, four expanding sections
// (Activity, Quote, Sale, Cancellation), one Log button. The button
// calls rp_log_entry, a SECURITY DEFINER RPC that writes every section
// in one transaction (it wraps rp_log_activity / rp_log_quote /
// rp_log_sale / rp_log_cancellation). Any failure rolls the whole entry
// back, so nothing is ever half-saved. The signed-in team member is
// resolved server-side; admins may log on someone's behalf via the
// "Log for" picker.
//
// Service tasks are counters: three tasks for one customer go in as
// three rows, each its own checkable, voidable credit. The sale section
// derives Multiline Sold + Referral Sold credits itself; nobody logs
// those by hand. Points are read from retention_point_values so a value
// change never touches this file. Week view calls
// compute_weekly_retention_points (the same number the pay function
// will consume).
// ============================================================

const PRODUCTS = [
  { key: "auto",     label: "Auto",                short: "Auto" },
  { key: "fire",     label: "Fire (home / renters)", short: "Fire" },
  { key: "business", label: "Business",            short: "Business" },
  { key: "life",     label: "Life",                short: "Life" },
  { key: "health",   label: "Health",              short: "Health" },
  { key: "ips",      label: "Investment (IPS)",    short: "IPS" },
  { key: "bank",     label: "Bank",                short: "Bank" },
];
const PRODUCT_LABEL = Object.fromEntries(PRODUCTS.map(p => [p.key, p.label]));
const PRODUCT_SHORT = Object.fromEntries(PRODUCTS.map(p => [p.key, p.short]));
const SERVICE_KEYS = ["service_task", "service_task_company", "service_task_coi"];
const TABS = ["log", "week"];
const MAX_COUNT = 50; // rp_log_entry refuses more than this of one item in a single entry

// ---------- styles ----------
const inputBase = {
  width: "100%", padding: "10px 12px", borderRadius: 8,
  border: `1px solid ${T.slate300}`, background: T.white, color: T.slate900,
  fontSize: 15, outline: "none", boxSizing: "border-box",
};
const labelStyle = { fontSize: 12, fontWeight: 600, color: T.slate600, marginBottom: 6, display: "block" };
const cardStyle = {
  background: T.white, borderRadius: 12, border: `1px solid ${T.slate200}`,
  padding: 20, boxShadow: "0 1px 2px rgba(0,0,0,0.04)",
};
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
const gridForm = { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: 12 };
const sectionWrap = (open) => ({
  border: `1px solid ${open ? T.blue : T.slate200}`, borderRadius: 10,
  background: open ? T.white : T.slate50, overflow: "hidden", boxSizing: "border-box",
});
const sectionHead = {
  display: "flex", flexWrap: "wrap", alignItems: "center", justifyContent: "space-between", gap: 10,
  width: "100%", padding: "12px 14px", background: "transparent", border: "none", cursor: "pointer",
  textAlign: "left", fontFamily: "inherit", color: T.slate900, boxSizing: "border-box",
};
const counterBtn = (disabled) => ({
  width: 34, height: 34, borderRadius: 8, border: `1px solid ${T.slate300}`, padding: 0, lineHeight: 1,
  background: disabled ? T.slate100 : T.white, color: disabled ? T.slate400 : T.slate800,
  fontSize: 18, fontWeight: 700, cursor: disabled ? "default" : "pointer", boxSizing: "border-box",
});

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
function tierName(label) {
  // "Service Task — Standard" -> "Standard"
  return String(label || "").replace(/^service task\s*[—–-]\s*/i, "");
}

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
        <label style={labelStyle}>Last initial {preview ? <span style={{ color: T.slate400, fontWeight: 400 }}>→ {preview}</span> : null}</label>
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

// A counter: minus, number, plus. Used for service tasks, which are counted
// per type. Zero means "none of these".
function Counter({ value, onChange }) {
  const v = Number(value) || 0;
  return (
    <div style={{ display: "inline-flex", alignItems: "center", gap: 6, flexShrink: 0 }}>
      <button type="button" style={counterBtn(v <= 0)} disabled={v <= 0} onClick={() => onChange(Math.max(0, v - 1))} aria-label="one less">−</button>
      <span style={{ minWidth: 28, textAlign: "center", fontSize: 16, fontWeight: 700, color: v > 0 ? T.slate900 : T.slate400 }}>{v}</span>
      <button type="button" style={counterBtn(v >= MAX_COUNT)} disabled={v >= MAX_COUNT} onClick={() => onChange(Math.min(MAX_COUNT, v + 1))} aria-label="one more">+</button>
    </div>
  );
}

// An expanding section of the entry. The header is a button (it only
// expands and collapses, it does not navigate). What is inside stays in
// the entry even while the section is collapsed; the summary pill on the
// right shows it, so nothing hides.
function Section({ title, hint, open, onToggle, summary, children }) {
  return (
    <div style={sectionWrap(open)}>
      <button type="button" style={sectionHead} onClick={onToggle} aria-expanded={open}>
        <span style={{ display: "flex", alignItems: "center", gap: 10, minWidth: 0 }}>
          <span style={{ fontSize: 13, color: T.slate500, width: 12, display: "inline-block" }}>{open ? "▾" : "▸"}</span>
          <span style={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}>{title}</span>
          {!open && hint ? <span style={{ fontSize: 12, color: T.slate500 }}>{hint}</span> : null}
        </span>
        {summary ? (
          <span style={{ fontSize: 12, fontWeight: 700, color: T.blue, background: T.blueLt, padding: "4px 10px", borderRadius: 999, whiteSpace: "nowrap" }}>{summary}</span>
        ) : null}
      </button>
      {open && <div style={{ padding: "4px 14px 16px" }}>{children}</div>}
    </div>
  );
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
  if (q) parts.push(`quote: ${(q.products_discussed || []).map(k => PRODUCT_SHORT[k] || k).join(", ")}`);
  const s = data?.sale;
  if (s) {
    const credits = (s.credits || []).map(c => c.activity_key === "multiline_sold" ? `Multiline (${PRODUCT_SHORT[c.line] || c.line})` : "Referral Sold");
    parts.push(`sale: $${fmtPts(s.total_premium)} premium` +
      (credits.length ? `, credited ${credits.join(", ")} = $${fmtPts(s.retention_points)}` : ", no multiline or referral credit"));
  }
  const c = data?.cancellation;
  if (c) {
    const voided = Number(c.saves_voided || 0);
    parts.push(`cancellation: ${PRODUCT_SHORT[c.policy_line] || c.policy_line}` +
      (voided > 0 ? `, ${voided} unpaid save taken back` : ""));
  }
  return `Logged for ${data?.customer || "the customer"}: ${parts.join("; ")}.`;
}

// =====================================================================
// Entry page — one customer, one contact, everything that happened.
// Activity, Quote, Sale, Cancellation as expanding sections; one Log
// button; one RPC (rp_log_entry) that saves all of it or none of it.
// =====================================================================
function EntryPage({ values, sources, isOwner, roster, onLogged, refreshKey }) {
  const today = todayCentral();
  // customer block (shared by every section)
  const [first, setFirst] = useState("");
  const [initial, setInitial] = useState("");
  const [date, setDate] = useState(today);
  const [logFor, setLogFor] = useState(null);
  const [ecrm, setEcrm] = useState("");
  const [note, setNote] = useState("");
  // which sections are expanded (form state, not URL state)
  const [open, setOpen] = useState({ activity: true, quote: false, sale: false, cancellation: false });
  // activity
  const [counts, setCounts] = useState({});    // service tier key -> count
  const [checked, setChecked] = useState({});  // other activity_key -> true
  const [saveLine, setSaveLine] = useState("");
  const [saveReason, setSaveReason] = useState("");
  // quote
  const [qProds, setQProds] = useState({});
  const [qExisting, setQExisting] = useState(false);
  // sale
  const [household, setHousehold] = useState("");
  const [source, setSource] = useState("");
  const [gnc, setGnc] = useState("");
  const [vehicles, setVehicles] = useState("");
  const [sourcedBy, setSourcedBy] = useState("");
  const [sProds, setSProds] = useState({});    // key -> { premium, policy_count, is_new_line }
  // cancellation
  const [cLine, setCLine] = useState("");
  const [cReason, setCReason] = useState("");
  // submit
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");

  const serviceTiers = (values || []).filter(v => SERVICE_KEYS.includes(v.activity_key));
  const loggable = (values || []).filter(v => v.category === "logged" && !SERVICE_KEYS.includes(v.activity_key));
  const byKey = useMemo(() => Object.fromEntries((values || []).map(v => [v.activity_key, v])), [values]);

  const toggleOpen = (id) => setOpen(o => ({ ...o, [id]: !o[id] }));
  const toggleSaleProduct = (k) => setSProds(p => {
    const n = { ...p };
    if (n[k]) delete n[k]; else n[k] = { premium: "", policy_count: 1, is_new_line: true };
    return n;
  });
  const setSaleProd = (k, field, val) => setSProds(p => ({ ...p, [k]: { ...p[k], [field]: val } }));

  // ---- what is in the entry right now ----
  const activityItems = [];
  for (const v of serviceTiers) {
    const n = Number(counts[v.activity_key]) || 0;
    if (n > 0) activityItems.push({ activity_key: v.activity_key, count: n });
  }
  for (const k of Object.keys(checked)) {
    if (!checked[k]) continue;
    if (k === "cancellation_saved") activityItems.push({ activity_key: k, save_line: saveLine, save_reason: saveReason.trim() });
    else activityItems.push({ activity_key: k });
  }
  const activityCount = activityItems.reduce((s, it) => s + (it.count || 1), 0);
  const activityTotal = activityItems.reduce((s, it) => s + Number(byKey[it.activity_key]?.points || 0) * (it.count || 1), 0);

  const quoteChosen = PRODUCTS.filter(p => qProds[p.key]).map(p => p.key);

  const saleSelected = PRODUCTS.filter(p => sProds[p.key]);
  const saleTotal = saleSelected.reduce((s, p) => s + (Number(sProds[p.key].premium) || 0), 0);
  const hasAuto = !!sProds.auto;

  const hasActivity = activityItems.length > 0;
  const hasQuote = quoteChosen.length > 0;
  const hasSale = saleSelected.length > 0;
  const hasCxl = !!cLine;
  const hasAnything = hasActivity || hasQuote || hasSale || hasCxl;
  const customerOk = !!first.trim() && /^[A-Za-z]$/.test(initial.trim());

  // ---- what still needs fixing, in plain words (mirrors the server rules) ----
  const problems = [];
  if (!customerOk) problems.push("Customer first name and last initial.");
  if (!hasAnything) problems.push("Open a section and add what happened.");
  if ((hasActivity || hasQuote) && date < addDays(today, -7)) problems.push("Activity and quotes are logged within 7 days. Pick a later date or split the entry.");
  if (hasSale && date < addDays(today, -30)) problems.push("A sale is logged within 30 days of the bind.");
  if (hasCxl && date < addDays(today, -90)) problems.push("A cancellation is logged within 90 days.");
  if (checked.cancellation_saved) {
    if (date !== today) problems.push("A save is logged the same business day it comes in. Set the date to today.");
    if (!saveLine || !saveReason.trim()) problems.push("The save needs the policy line at risk and the reason the customer gave.");
  }
  if (checked.policy_review && !note.trim()) problems.push("The policy review needs a note on what you covered.");
  if (hasSale) {
    if (!household) problems.push("Sale: new household or existing customer?");
    if (!source) problems.push("Sale: pick the marketing source.");
    if (gnc === "") problems.push("Sale: was Good Neighbor Connect used?");
    if (!ecrm.trim()) problems.push("Sale: the ECRM opportunity link is required.");
    if (saleSelected.some(p => sProds[p.key].premium === "" || !(Number(sProds[p.key].premium) >= 0))) problems.push("Sale: every product needs its premium.");
    if (hasAuto && !(Number(vehicles) >= 1)) problems.push("Sale: how many cars?");
  }
  if (hasSale && hasCxl && sProds[cLine]) problems.push(`${PRODUCT_SHORT[cLine]} is both sold and cancelled in this entry. Log those as two entries.`);
  if (ecrm.trim() && !/^https?:\/\//i.test(ecrm.trim())) problems.push("The ECRM link must start with http.");
  const canSubmit = !busy && problems.length === 0;
  const started = hasAnything || !!first.trim() || !!initial.trim();

  const reset = () => {
    setFirst(""); setInitial(""); setDate(today); setEcrm(""); setNote("");
    setCounts({}); setChecked({}); setSaveLine(""); setSaveReason("");
    setQProds({}); setQExisting(false);
    setHousehold(""); setSource(""); setGnc(""); setVehicles(""); setSourcedBy(""); setSProds({});
    setCLine(""); setCReason("");
  };

  const submit = async () => {
    setErr(""); setOk("");
    if (!canSubmit) return;
    setBusy(true);
    try {
      const payload = {
        customer_first: first.trim(), customer_last_initial: initial.trim(), occurred_on: date,
        ecrm_url: ecrm.trim() || null, note: note.trim() || null, team_member_id: logFor,
        activity: hasActivity ? { items: activityItems } : null,
        quote: hasQuote ? { products_discussed: quoteChosen, is_existing_customer: qExisting } : null,
        sale: hasSale ? {
          household_status: household, marketing_source: source, gnc_used: gnc === "yes",
          vehicle_count: hasAuto ? Number(vehicles) : null, sourced_by_team_member_id: sourcedBy || null,
          products: saleSelected.map(p => ({
            line_of_business: p.key, premium: Number(sProds[p.key].premium),
            policy_count: Math.max(1, Number(sProds[p.key].policy_count) || 1),
            is_new_line: household === "new" ? true : !!sProds[p.key].is_new_line,
          })),
        } : null,
        cancellation: hasCxl ? { policy_line: cLine, reason: cReason.trim() || null } : null,
      };
      const { data, error } = await supabase.rpc("rp_log_entry", { p_payload: payload });
      if (error) { setErr(errText(error)); return; }
      if (!data?.ok) { setErr(errText(data)); return; }
      setOk(summarizeEntry(data));
      reset();
      onLogged?.();
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  };

  const activitySummary = hasActivity ? `${activityCount} · $${fmtPts(activityTotal)}` : "";
  const quoteSummary = hasQuote ? quoteChosen.map(k => PRODUCT_SHORT[k]).join(", ") : "";
  const saleSummary = hasSale ? `$${fmtPts(saleTotal)} · ${saleSelected.map(p => p.short).join(", ")}` : "";
  const cxlSummary = hasCxl ? PRODUCT_SHORT[cLine] : "";

  return (
    <div>
      <div style={cardStyle}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>Log an entry</div>
        <div style={{ fontSize: 13, color: T.slate500, marginBottom: 16 }}>One customer, one contact, everything that happened. Open the sections you need. One button saves it all.</div>

        <div style={gridForm}>
          <CustomerFields first={first} setFirst={setFirst} initial={initial} setInitial={setInitial} />
          <div>
            <label style={labelStyle}>Date</label>
            <input type="date" style={inputBase} value={date} max={today} min={addDays(today, -90)} onChange={e => setDate(e.target.value)} />
          </div>
          <LogForPicker canLogForOthers={isOwner} roster={roster} value={logFor} onChange={setLogFor} />
        </div>

        <div style={{ display: "grid", gap: 10, marginTop: 18 }}>
          {/* ---------------- Activity ---------------- */}
          <Section title="Activity" hint="service tasks, reviews, saves, and the rest" open={open.activity} onToggle={() => toggleOpen("activity")} summary={activitySummary}>
            <label style={labelStyle}>Service tasks <span style={{ color: T.slate400, fontWeight: 400 }}>(count each one you finished)</span></label>
            <div style={{ display: "grid", gap: 8 }}>
              {serviceTiers.map(v => (
                <div key={v.activity_key} style={{ display: "flex", flexWrap: "wrap", alignItems: "center", justifyContent: "space-between", gap: 10, padding: "10px 12px", background: T.slate50, borderRadius: 8 }}>
                  <div style={{ minWidth: 0, flex: "1 1 220px" }}>
                    <div style={{ fontSize: 14, fontWeight: 700, color: T.slate800 }}>{tierName(v.label)} <span style={{ color: T.slate500, fontWeight: 400 }}>· ${fmtPts(v.points)} each</span></div>
                    <div style={{ fontSize: 12, color: T.slate500, marginTop: 2, lineHeight: 1.4 }}>{v.description}</div>
                  </div>
                  <Counter value={counts[v.activity_key] || 0} onChange={n => setCounts(c => ({ ...c, [v.activity_key]: n }))} />
                </div>
              ))}
              {serviceTiers.length === 0 && <div style={{ fontSize: 12, color: T.slate500 }}>No service task tiers are set up.</div>}
            </div>

            <div style={{ marginTop: 14 }}>
              <label style={labelStyle}>Also</label>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
                {loggable.map(v => (
                  <span key={v.activity_key} style={chip(!!checked[v.activity_key])} onClick={() => setChecked(c => ({ ...c, [v.activity_key]: !c[v.activity_key] }))}>
                    {v.label} · ${fmtPts(v.points)}
                  </span>
                ))}
              </div>
            </div>

            {checked.cancellation_saved && (
              <div style={{ ...gridForm, marginTop: 14, padding: 12, background: T.slate50, borderRadius: 8 }}>
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
          </Section>

          {/* ---------------- Quote ---------------- */}
          <Section title="Quote" hint="every product you discussed" open={open.quote} onToggle={() => toggleOpen("quote")} summary={quoteSummary}>
            <label style={labelStyle}>Products discussed <span style={{ color: T.slate400, fontWeight: 400 }}>(click every one, not just the one they asked about)</span></label>
            <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
              {PRODUCTS.map(p => <span key={p.key} style={chip(!!qProds[p.key])} onClick={() => setQProds(x => ({ ...x, [p.key]: !x[p.key] }))}>{p.label}</span>)}
            </div>
            <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: T.slate700, marginTop: 14 }}>
              <input type="checkbox" checked={qExisting} onChange={e => setQExisting(e.target.checked)} />
              Existing customer
            </label>
          </Section>

          {/* ---------------- Sale ---------------- */}
          <Section title="Sale" hint="a bound policy" open={open.sale} onToggle={() => toggleOpen("sale")} summary={saleSummary}>
            <div style={{ fontSize: 12, color: T.slate500, marginBottom: 12 }}>Everything here is required, plus the ECRM link below. Multiline Sold and Referral Sold points are credited automatically to whoever sourced the sale.</div>
            <div style={gridForm}>
              <div>
                <label style={labelStyle}>Household</label>
                <select style={inputBase} value={household} onChange={e => setHousehold(e.target.value)}>
                  <option value="">Pick one</option>
                  <option value="new">New household</option>
                  <option value="existing">Existing customer</option>
                </select>
              </div>
              <div>
                <label style={labelStyle}>Marketing source</label>
                <select style={inputBase} value={source} onChange={e => setSource(e.target.value)}>
                  <option value="">Pick one</option>
                  {(sources || []).map(s => <option key={s.source_key} value={s.source_key}>{s.label}</option>)}
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
              <div>
                <label style={labelStyle}>Who sourced this sale?</label>
                <select style={inputBase} value={sourcedBy} onChange={e => setSourcedBy(e.target.value)}>
                  <option value="">{logFor ? "The person logged for" : "Me"}</option>
                  {(roster || []).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
                </select>
              </div>
            </div>

            <div style={{ marginTop: 14 }}>
              <label style={labelStyle}>Products sold <span style={{ color: T.slate400, fontWeight: 400 }}>(click every one)</span></label>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
                {PRODUCTS.map(p => <span key={p.key} style={chip(!!sProds[p.key])} onClick={() => toggleSaleProduct(p.key)}>{p.label}</span>)}
              </div>
            </div>

            {saleSelected.length > 0 && (
              <div style={{ marginTop: 12, display: "grid", gap: 10 }}>
                {saleSelected.map(p => (
                  <div key={p.key} style={{ ...gridForm, padding: 12, background: T.slate50, borderRadius: 8, alignItems: "end" }}>
                    <div style={{ fontWeight: 700, color: T.slate800, alignSelf: "center" }}>{p.label}</div>
                    <div>
                      <label style={labelStyle}>Premium</label>
                      <input type="number" inputMode="decimal" min="0" step="0.01" style={inputBase} value={sProds[p.key].premium} onChange={e => setSaleProd(p.key, "premium", e.target.value)} placeholder="0.00" />
                    </div>
                    {p.key === "auto" && (
                      <div>
                        <label style={labelStyle}>How many cars?</label>
                        <input type="number" inputMode="numeric" min="1" step="1" style={inputBase} value={vehicles} onChange={e => setVehicles(e.target.value)} placeholder="1" />
                      </div>
                    )}
                    <div>
                      <label style={labelStyle}>Policies</label>
                      <input type="number" inputMode="numeric" min="1" step="1" style={inputBase} value={sProds[p.key].policy_count} onChange={e => setSaleProd(p.key, "policy_count", e.target.value)} />
                    </div>
                    {household === "existing" && (
                      <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: T.slate700, paddingBottom: 10 }}>
                        <input type="checkbox" checked={!!sProds[p.key].is_new_line} onChange={e => setSaleProd(p.key, "is_new_line", e.target.checked)} />
                        New line for this household
                      </label>
                    )}
                  </div>
                ))}
                <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "baseline" }}>
                  <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>Total premium: ${fmtPts(saleTotal)}</div>
                  {household === "new" && saleSelected.length > 1 && <span style={{ fontSize: 12, color: T.slate500 }}>New household: every line beyond the biggest one counts as a multiline.</span>}
                </div>
              </div>
            )}
          </Section>

          {/* ---------------- Cancellation ---------------- */}
          <Section title="Cancellation" hint="a policy that cancelled anyway" open={open.cancellation} onToggle={() => toggleOpen("cancellation")} summary={cxlSummary}>
            <div style={{ fontSize: 12, color: T.slate500, marginBottom: 12 }}>If someone logged a save on the same customer and line and that credit has not been paid yet, this takes it back.</div>
            <label style={labelStyle}>Which policy cancelled</label>
            <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
              {PRODUCTS.map(p => (
                <span key={p.key} style={chip(cLine === p.key)} onClick={() => setCLine(cLine === p.key ? "" : p.key)}>{p.label}</span>
              ))}
            </div>
            <div style={{ marginTop: 14 }}>
              <label style={labelStyle}>Reason <span style={{ color: T.slate400, fontWeight: 400 }}>(optional)</span></label>
              <input style={inputBase} value={cReason} onChange={e => setCReason(e.target.value)} placeholder="what they told us" />
            </div>
          </Section>
        </div>

        <div style={{ ...gridForm, marginTop: 16 }}>
          <div style={{ gridColumn: "1 / -1" }}>
            <label style={labelStyle}>ECRM link {hasSale ? <span style={{ color: T.red }}>(required for a sale)</span> : <span style={{ color: T.slate400, fontWeight: 400 }}>(optional)</span>}</label>
            <input style={inputBase} value={ecrm} onChange={e => setEcrm(e.target.value)} placeholder="https://…" />
          </div>
          <div style={{ gridColumn: "1 / -1" }}>
            <label style={labelStyle}>Note {checked.policy_review ? <span style={{ color: T.red }}>(what you covered, required for a policy review)</span> : <span style={{ color: T.slate400, fontWeight: 400 }}>(optional)</span>}</label>
            <input style={inputBase} value={note} onChange={e => setNote(e.target.value)} placeholder="Reviewed liability limits and umbrella; added rental reimbursement" />
          </div>
        </div>

        <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", marginTop: 18 }}>
          <button style={btnPrimary(!canSubmit)} disabled={!canSubmit} onClick={submit}>{busy ? "Saving…" : `Log it${activityTotal ? ` · $${fmtPts(activityTotal)}` : ""}`}</button>
          <span style={{ fontSize: 12, color: T.slate500 }}>Multiline Sold and Referral Sold come from the sale automatically.</span>
        </div>
        {started && problems.length > 0 && (
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
        A save pays once the policy has stayed active 30 days. If one of these cancelled anyway, log the cancellation above and the credit comes off before it is ever paid.
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
                  <td style={tableTd}>{r.household_status === "new" ? "New" : "Existing"}</td>
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
      const [v, s, r, me] = await Promise.all([
        supabase.from("retention_point_values").select("activity_key, label, points, category, requires_note, sort_order, description").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("sales_marketing_sources").select("source_key, label, sort_order").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("team_directory").select("id, first_name, role_category, is_admin_backoffice, is_test_user, archived_at, category").eq("agency_id", AGENCY_ID).eq("is_active", true).order("first_name"),
        supabase.rpc("current_team_member_id"),
      ]);
      if (!alive) return;
      setValues(Array.isArray(v.data) ? v.data : []);
      setSources(Array.isArray(s.data) ? s.data : []);
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
          <div style={{ fontSize: 20, fontWeight: 800, color: T.slate900 }}>Activity Log</div>
          <div style={{ fontSize: 13, color: T.slate500 }}>Retention Points, sales, quotes, and cancellations. Logged as they happen.</div>
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

      {tab === "log"  && <EntryPage values={values} sources={sources} isOwner={isOwner} roster={roster} onLogged={bump} refreshKey={refreshKey} />}
      {tab === "week" && <WeekView isAdmin={isAdmin} myTeamId={myTeamId} roster={roster} values={values} refreshKey={refreshKey} />}
    </div>
  );
}
