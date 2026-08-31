import { useState, useEffect, useMemo, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { T } from "../lib/theme.js";

// ============================================================
// ActivityLog — team capture for Retention Points, sales, quotes
//
// Three entry forms + a week view. Every write goes through a
// SECURITY DEFINER RPC (rp_log_activity / rp_log_sale / rp_log_quote)
// that resolves the signed-in team member server-side; admins may
// log on someone's behalf via the "Log for" picker.
//
// Sale entry derives Multiline Sold + Referral Sold credits itself —
// nobody logs those by hand. Points are read from
// retention_point_values so a value change never touches this file.
// Week view calls compute_weekly_retention_points (the same number
// the pay function will consume).
// ============================================================

const PRODUCTS = [
  { key: "auto",     label: "Auto" },
  { key: "fire",     label: "Fire (home / renters)" },
  { key: "business", label: "Business" },
  { key: "life",     label: "Life" },
  { key: "health",   label: "Health" },
  { key: "ips",      label: "Investment (IPS)" },
  { key: "bank",     label: "Bank" },
];
const PRODUCT_LABEL = Object.fromEntries(PRODUCTS.map(p => [p.key, p.label]));
const SERVICE_KEYS = ["service_task", "service_task_company", "service_task_coi"];
const TABS = ["log", "sale", "quote", "week"];

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

function LogForPicker({ isAdmin, roster, value, onChange }) {
  if (!isAdmin) return null;
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

// =====================================================================
// Activity form — one customer contact, several credits
// =====================================================================
function ActivityForm({ values, isAdmin, roster, onLogged }) {
  const [first, setFirst] = useState("");
  const [initial, setInitial] = useState("");
  const [date, setDate] = useState(todayCentral());
  const [ecrm, setEcrm] = useState("");
  const [note, setNote] = useState("");
  const [checked, setChecked] = useState({});   // activity_key -> true
  const [serviceTier, setServiceTier] = useState("");
  const [saveLine, setSaveLine] = useState("");
  const [saveReason, setSaveReason] = useState("");
  const [logFor, setLogFor] = useState(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");

  const loggable = (values || []).filter(v => v.category === "logged" && !SERVICE_KEYS.includes(v.activity_key));
  const serviceTiers = (values || []).filter(v => SERVICE_KEYS.includes(v.activity_key));
  const byKey = useMemo(() => Object.fromEntries((values || []).map(v => [v.activity_key, v])), [values]);

  const items = [];
  if (serviceTier) items.push({ activity_key: serviceTier });
  for (const k of Object.keys(checked)) {
    if (!checked[k]) continue;
    if (k === "cancellation_saved") items.push({ activity_key: k, save_line: saveLine, save_reason: saveReason });
    else items.push({ activity_key: k });
  }
  const total = items.reduce((s, it) => s + Number(byKey[it.activity_key]?.points || 0), 0);
  const canSubmit = !busy && items.length > 0 && first.trim() && /^[A-Za-z]$/.test(initial.trim());

  const reset = () => { setChecked({}); setServiceTier(""); setSaveLine(""); setSaveReason(""); setNote(""); setEcrm(""); setFirst(""); setInitial(""); };

  const submit = async () => {
    setErr(""); setOk("");
    if (checked.cancellation_saved && (!saveLine || !saveReason.trim())) { setErr("A save needs the policy line and the reason the customer gave."); return; }
    if (checked.policy_review && !note.trim()) { setErr("A policy review needs a note on what you covered."); return; }
    setBusy(true);
    try {
      const { data, error } = await supabase.rpc("rp_log_activity", {
        p_items: items, p_customer_first: first.trim(), p_customer_last_initial: initial.trim(),
        p_occurred_on: date, p_ecrm_url: ecrm.trim() || null, p_note: note.trim() || null, p_team_member_id: logFor,
      });
      if (error) { setErr(errText(error)); return; }
      if (!data?.ok) { setErr(errText(data)); return; }
      const pend = (data.items || []).filter(i => i.credit_available_on);
      setOk(`Logged ${data.items?.length || 0} item${data.items?.length === 1 ? "" : "s"} for ${data.customer} — $${fmtPts(data.points_total)}` +
            (pend.length ? ` (save clears ${fmtDate(pend[0].credit_available_on)})` : ""));
      reset();
      onLogged?.();
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  };

  return (
    <div style={cardStyle}>
      <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>Log what you did</div>
      <div style={{ fontSize: 13, color: T.slate500, marginBottom: 16 }}>One customer contact can earn several at once. Check everything that applies.</div>

      <div style={gridForm}>
        <CustomerFields first={first} setFirst={setFirst} initial={initial} setInitial={setInitial} />
        <div>
          <label style={labelStyle}>Date</label>
          <input type="date" style={inputBase} value={date} max={todayCentral()} min={addDays(todayCentral(), -7)} onChange={e => setDate(e.target.value)} />
        </div>
        <LogForPicker isAdmin={isAdmin} roster={roster} value={logFor} onChange={setLogFor} />
      </div>

      <div style={{ marginTop: 18 }}>
        <label style={labelStyle}>Service task <span style={{ color: T.slate400, fontWeight: 400 }}>(pick the one that fits)</span></label>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
          {serviceTiers.map(v => (
            <span key={v.activity_key} style={chip(serviceTier === v.activity_key)} onClick={() => setServiceTier(serviceTier === v.activity_key ? "" : v.activity_key)}>
              {v.label.replace("Service task — ", "")} · ${fmtPts(v.points)}
            </span>
          ))}
        </div>
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

      <div style={{ ...gridForm, marginTop: 14 }}>
        <div style={{ gridColumn: "1 / -1" }}>
          <label style={labelStyle}>Note {checked.policy_review ? <span style={{ color: T.red }}>(what you covered — required for a policy review)</span> : <span style={{ color: T.slate400, fontWeight: 400 }}>(optional)</span>}</label>
          <input style={inputBase} value={note} onChange={e => setNote(e.target.value)} placeholder="Reviewed liability limits and umbrella; added rental reimbursement" />
        </div>
        <div style={{ gridColumn: "1 / -1" }}>
          <label style={labelStyle}>ECRM link <span style={{ color: T.slate400, fontWeight: 400 }}>(optional)</span></label>
          <input style={inputBase} value={ecrm} onChange={e => setEcrm(e.target.value)} placeholder="https://…" />
        </div>
      </div>

      <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", marginTop: 18 }}>
        <button style={btnPrimary(!canSubmit)} disabled={!canSubmit} onClick={submit}>{busy ? "Saving…" : `Log it${total ? ` · $${fmtPts(total)}` : ""}`}</button>
        <span style={{ fontSize: 12, color: T.slate500 }}>Multiline Sold and Referral Sold come from the Sale tab automatically.</span>
      </div>
      <Notice kind="error">{err}</Notice>
      <Notice kind="ok">{ok}</Notice>
    </div>
  );
}

// =====================================================================
// Sale form — structured, required fields; derives Multiline + Referral RP
// =====================================================================
function SaleForm({ sources, isAdmin, roster, myTeamId, onLogged }) {
  const [first, setFirst] = useState("");
  const [initial, setInitial] = useState("");
  const [date, setDate] = useState(todayCentral());
  const [household, setHousehold] = useState("");
  const [ecrm, setEcrm] = useState("");
  const [source, setSource] = useState("");
  const [gnc, setGnc] = useState("");
  const [vehicles, setVehicles] = useState("");
  const [sourcedBy, setSourcedBy] = useState("");
  const [products, setProducts] = useState({}); // key -> { premium, policy_count, is_new_line }
  const [note, setNote] = useState("");
  const [logFor, setLogFor] = useState(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");

  const toggleProduct = (k) => setProducts(p => {
    const n = { ...p };
    if (n[k]) delete n[k]; else n[k] = { premium: "", policy_count: 1, is_new_line: true };
    return n;
  });
  const setProd = (k, field, val) => setProducts(p => ({ ...p, [k]: { ...p[k], [field]: val } }));

  const selected = PRODUCTS.filter(p => products[p.key]);
  const total = selected.reduce((s, p) => s + (Number(products[p.key].premium) || 0), 0);
  const hasAuto = !!products.auto;
  const canSubmit = !busy && first.trim() && /^[A-Za-z]$/.test(initial.trim()) && household && ecrm.trim() && source && gnc !== "" &&
    selected.length > 0 && selected.every(p => products[p.key].premium !== "" && Number(products[p.key].premium) >= 0) &&
    (!hasAuto || Number(vehicles) >= 1);

  const reset = () => { setFirst(""); setInitial(""); setHousehold(""); setEcrm(""); setSource(""); setGnc(""); setVehicles(""); setSourcedBy(""); setProducts({}); setNote(""); };

  const submit = async () => {
    setErr(""); setOk(""); setBusy(true);
    try {
      const payload = {
        sale_date: date, customer_first: first.trim(), customer_last_initial: initial.trim(),
        household_status: household, ecrm_opportunity_url: ecrm.trim(), marketing_source: source,
        gnc_used: gnc === "yes", vehicle_count: hasAuto ? Number(vehicles) : null, note: note.trim() || null,
        team_member_id: logFor, sourced_by_team_member_id: sourcedBy || null,
        products: selected.map(p => ({
          line_of_business: p.key, premium: Number(products[p.key].premium),
          policy_count: Math.max(1, Number(products[p.key].policy_count) || 1),
          is_new_line: household === "new" ? true : !!products[p.key].is_new_line,
        })),
      };
      const { data, error } = await supabase.rpc("rp_log_sale", { p_payload: payload });
      if (error) { setErr(errText(error)); return; }
      if (!data?.ok) { setErr(errText(data)); return; }
      const credits = (data.credits || []).map(c => c.activity_key === "multiline_sold" ? `Multiline (${PRODUCT_LABEL[c.line] || c.line})` : "Referral Sold");
      setOk(`Sale logged for ${data.customer} — $${fmtPts(data.total_premium)} premium.` +
            (credits.length ? ` Retention Points credited: ${credits.join(", ")} = $${fmtPts(data.retention_points)}.` : " No multiline or referral credit on this one."));
      reset();
      onLogged?.();
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  };

  return (
    <div style={cardStyle}>
      <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>Log a sale</div>
      <div style={{ fontSize: 13, color: T.slate500, marginBottom: 16 }}>Everything here is required. Multiline Sold and Referral Sold points are credited automatically to whoever sourced the sale.</div>

      <div style={gridForm}>
        <CustomerFields first={first} setFirst={setFirst} initial={initial} setInitial={setInitial} />
        <div>
          <label style={labelStyle}>Bind date</label>
          <input type="date" style={inputBase} value={date} max={todayCentral()} min={addDays(todayCentral(), -30)} onChange={e => setDate(e.target.value)} />
        </div>
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
        <LogForPicker isAdmin={isAdmin} roster={roster} value={logFor} onChange={setLogFor} />
        <div style={{ gridColumn: "1 / -1" }}>
          <label style={labelStyle}>ECRM opportunity link</label>
          <input style={inputBase} value={ecrm} onChange={e => setEcrm(e.target.value)} placeholder="https://…" />
        </div>
      </div>

      <div style={{ marginTop: 18 }}>
        <label style={labelStyle}>Products sold <span style={{ color: T.slate400, fontWeight: 400 }}>(click every one)</span></label>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
          {PRODUCTS.map(p => <span key={p.key} style={chip(!!products[p.key])} onClick={() => toggleProduct(p.key)}>{p.label}</span>)}
        </div>
      </div>

      {selected.length > 0 && (
        <div style={{ marginTop: 14, display: "grid", gap: 10 }}>
          {selected.map(p => (
            <div key={p.key} style={{ ...gridForm, padding: 12, background: T.slate50, borderRadius: 8, alignItems: "end" }}>
              <div style={{ fontWeight: 700, color: T.slate800, alignSelf: "center" }}>{p.label}</div>
              <div>
                <label style={labelStyle}>Premium</label>
                <input type="number" inputMode="decimal" min="0" step="0.01" style={inputBase} value={products[p.key].premium} onChange={e => setProd(p.key, "premium", e.target.value)} placeholder="0.00" />
              </div>
              {p.key === "auto" && (
                <div>
                  <label style={labelStyle}>How many cars?</label>
                  <input type="number" inputMode="numeric" min="1" step="1" style={inputBase} value={vehicles} onChange={e => setVehicles(e.target.value)} placeholder="1" />
                </div>
              )}
              <div>
                <label style={labelStyle}>Policies</label>
                <input type="number" inputMode="numeric" min="1" step="1" style={inputBase} value={products[p.key].policy_count} onChange={e => setProd(p.key, "policy_count", e.target.value)} />
              </div>
              {household === "existing" && (
                <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: T.slate700, paddingBottom: 10 }}>
                  <input type="checkbox" checked={!!products[p.key].is_new_line} onChange={e => setProd(p.key, "is_new_line", e.target.checked)} />
                  New line for this household
                </label>
              )}
            </div>
          ))}
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>Total premium: ${fmtPts(total)}</div>
        </div>
      )}

      <div style={{ marginTop: 14 }}>
        <label style={labelStyle}>Note <span style={{ color: T.slate400, fontWeight: 400 }}>(optional)</span></label>
        <input style={inputBase} value={note} onChange={e => setNote(e.target.value)} />
      </div>

      <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", marginTop: 18 }}>
        <button style={btnPrimary(!canSubmit)} disabled={!canSubmit} onClick={submit}>{busy ? "Saving…" : "Log sale"}</button>
        {household === "new" && selected.length > 1 && <span style={{ fontSize: 12, color: T.slate500 }}>New household: every line beyond the biggest one counts as a multiline.</span>}
      </div>
      <Notice kind="error">{err}</Notice>
      <Notice kind="ok">{ok}</Notice>
    </div>
  );
}

// =====================================================================
// Quote form — click every product discussed
// =====================================================================
function QuoteForm({ isAdmin, roster, onLogged }) {
  const [first, setFirst] = useState("");
  const [initial, setInitial] = useState("");
  const [date, setDate] = useState(todayCentral());
  const [existing, setExisting] = useState(false);
  const [prods, setProds] = useState({});
  const [ecrm, setEcrm] = useState("");
  const [note, setNote] = useState("");
  const [logFor, setLogFor] = useState(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");

  const chosen = PRODUCTS.filter(p => prods[p.key]).map(p => p.key);
  const canSubmit = !busy && first.trim() && /^[A-Za-z]$/.test(initial.trim()) && chosen.length > 0;

  const submit = async () => {
    setErr(""); setOk(""); setBusy(true);
    try {
      const { data, error } = await supabase.rpc("rp_log_quote", { p_payload: {
        quote_date: date, customer_first: first.trim(), customer_last_initial: initial.trim(), is_existing_customer: existing,
        products_discussed: chosen, ecrm_opportunity_url: ecrm.trim() || null, note: note.trim() || null, team_member_id: logFor,
      }});
      if (error) { setErr(errText(error)); return; }
      if (!data?.ok) { setErr(errText(data)); return; }
      setOk(`Quote logged for ${data.customer}: ${(data.products_discussed || []).map(k => PRODUCT_LABEL[k] || k).join(", ")}.`);
      setFirst(""); setInitial(""); setProds({}); setEcrm(""); setNote(""); setExisting(false);
      onLogged?.();
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  };

  return (
    <div style={cardStyle}>
      <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>Log a quote</div>
      <div style={{ fontSize: 13, color: T.slate500, marginBottom: 16 }}>One entry per quote conversation. Click every product you discussed, not just the one they asked about.</div>
      <div style={gridForm}>
        <CustomerFields first={first} setFirst={setFirst} initial={initial} setInitial={setInitial} />
        <div>
          <label style={labelStyle}>Date</label>
          <input type="date" style={inputBase} value={date} max={todayCentral()} min={addDays(todayCentral(), -7)} onChange={e => setDate(e.target.value)} />
        </div>
        <LogForPicker isAdmin={isAdmin} roster={roster} value={logFor} onChange={setLogFor} />
      </div>
      <div style={{ marginTop: 18 }}>
        <label style={labelStyle}>Products discussed</label>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
          {PRODUCTS.map(p => <span key={p.key} style={chip(!!prods[p.key])} onClick={() => setProds(x => ({ ...x, [p.key]: !x[p.key] }))}>{p.label}</span>)}
        </div>
      </div>
      <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: T.slate700, marginTop: 14 }}>
        <input type="checkbox" checked={existing} onChange={e => setExisting(e.target.checked)} />
        Existing customer
      </label>
      <div style={{ ...gridForm, marginTop: 14 }}>
        <div style={{ gridColumn: "1 / -1" }}>
          <label style={labelStyle}>ECRM opportunity link <span style={{ color: T.slate400, fontWeight: 400 }}>(optional)</span></label>
          <input style={inputBase} value={ecrm} onChange={e => setEcrm(e.target.value)} placeholder="https://…" />
        </div>
        <div style={{ gridColumn: "1 / -1" }}>
          <label style={labelStyle}>Note <span style={{ color: T.slate400, fontWeight: 400 }}>(optional)</span></label>
          <input style={inputBase} value={note} onChange={e => setNote(e.target.value)} />
        </div>
      </div>
      <div style={{ marginTop: 18 }}>
        <button style={btnPrimary(!canSubmit)} disabled={!canSubmit} onClick={submit}>{busy ? "Saving…" : "Log quote"}</button>
      </div>
      <Notice kind="error">{err}</Notice>
      <Notice kind="ok">{ok}</Notice>
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
              <th style={tableTh}>Who</th><th style={tableTh}>Hours in office</th><th style={tableTh}>Calls answered</th><th style={tableTh}>Missed %</th>
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

  useEffect(() => {
    let alive = true;
    (async () => {
      const [v, s, r, me] = await Promise.all([
        supabase.from("retention_point_values").select("activity_key, label, points, category, requires_note, sort_order").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
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
    { id: "log", label: "Log activity" },
    { id: "sale", label: "Log a sale" },
    { id: "quote", label: "Log a quote" },
    { id: "week", label: "My week" },
  ];

  return (
    <div style={{ padding: _pad, display: "grid", gap: 16 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", justifyContent: "space-between" }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 800, color: T.slate900 }}>Activity Log</div>
          <div style={{ fontSize: 13, color: T.slate500 }}>Retention Points, sales, and quotes — logged as they happen.</div>
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

      {tab === "log"   && <ActivityForm values={values} isAdmin={isAdmin} roster={roster} onLogged={bump} />}
      {tab === "sale"  && <SaleForm sources={sources} isAdmin={isAdmin} roster={roster} myTeamId={myTeamId} onLogged={bump} />}
      {tab === "quote" && <QuoteForm isAdmin={isAdmin} roster={roster} onLogged={bump} />}
      {tab === "week"  && <WeekView isAdmin={isAdmin} myTeamId={myTeamId} roster={roster} values={values} refreshKey={refreshKey} />}
    </div>
  );
}
