import { useState, useEffect, useMemo } from "react";
import { supabase } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { T } from "../lib/theme.js";
import { CustomerName } from "../lib/customerAccount.jsx";

// Dashboard > Backfill. The imported history came in without the last four
// phone digits, without the ECRM link on the sale, and on some rows without a
// marketing source, referral detail, or issued premium. This is what is still
// missing, one card per household (Peter 2026-09-20).
//
// The split that matters: the phone and the marketing source belong to the
// HOUSEHOLD, so they are typed once at the top of the card and land on every
// record under that name that has none. The ECRM link and the issued premium
// belong to the RECORD, so they stay on the record.
//
// The rule that matters: nothing is written unless you typed it. A box that
// shows what is already on file is only showing it. The premium the policy was
// submitted at sits under an empty issued premium box as a one-tap suggestion,
// so accepting it is a deliberate tap, never something a Save sweeps up.
//
// Save one household, or save every household you have touched. Cancelations
// never appear here: each takes its phone from the sale product it cancels.
// Issuing goes through rp_mark_issued, same as the To Be Issued tab. Reads
// rp_backfill_queue, writes rp_backfill_save. Owner and managers only.

const PAGE = 25;   // households per page, not records

export default function BackfillTab({ sources = [], roster = [] }) {
  const _vp = useViewport();
  const [households, setHouseholds] = useState([]);
  const [totalHouseholds, setTotalHouseholds] = useState(null);
  const [totalRows, setTotalRows] = useState(null);
  const [offset, setOffset] = useState(0);
  const [edits, setEdits] = useState({});       // per record: ecrm, policies
  const [hhEdits, setHhEdits] = useState({});   // per household: phone, source, referral
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");
  const [box, setBox] = useState("");
  const [search, setSearch] = useState("");
  const [searching, setSearching] = useState(false);
  // The list is paged on the server, so the sort has to be too. Otherwise
  // "sort by name" only sorts the households on screen.
  const [sort, setSort] = useState({ by: "date", dir: "desc" });

  const load = async (from, q, s) => {
    setLoading(true);
    setErr("");
    const order = s ?? sort;
    const { data, error } = await supabase.rpc("rp_backfill_queue", {
      p_limit: PAGE,
      p_offset: from,
      p_search: (q ?? search) || null,
      p_sort: order.by,
      p_dir: order.dir,
    });
    if (error) {
      setErr(error.message || "Could not load the list.");
      setLoading(false);
      return;
    }
    setHouseholds(Array.isArray(data?.households) ? data.households : []);
    setTotalHouseholds(Number(data?.total_households || 0));
    setTotalRows(Number(data?.total_rows || 0));
    setSearching(!!data?.searching);
    setEdits({});
    setHhEdits({});
    setLoading(false);
  };

  useEffect(() => { load(offset); }, [offset]); // eslint-disable-line react-hooks/exhaustive-deps

  // Pull up a customer by name, whether or not anything is missing on them.
  const runSearch = (q) => {
    setSearch(q);
    setOffset(0);
    load(0, q);
  };

  // Click a heading to sort by it. The same heading again flips the direction.
  const sortBy = (by) => {
    const next = sort.by === by
      ? { by, dir: sort.dir === "asc" ? "desc" : "asc" }
      : { by, dir: by === "date" ? "desc" : "asc" };
    setSort(next);
    setOffset(0);
    load(0, undefined, next);
  };
  const sortArrow = (by) => sort.by !== by ? "" : sort.dir === "asc" ? " \u25B2" : " \u25BC";

  const srcLabel = useMemo(() => {
    const m = {};
    (sources || []).forEach(s => { m[s.source_key] = s.label || s.source_key; });
    return m;
  }, [sources]);

  // ---- what has been typed -------------------------------------------------
  const hhTyped = (h, field) => {
    const e = hhEdits[h.household] || {};
    return e[field] !== undefined ? e[field] : "";
  };
  const setHh = (h, field, value) => {
    setHhEdits(prev => ({ ...prev, [h.household]: { ...(prev[h.household] || {}), [field]: value } }));
  };

  const polTyped = (r, pid, field) => {
    const pol = ((edits[r.id] || {}).policies || {})[pid] || {};
    return pol[field] !== undefined ? pol[field] : "";
  };
  const setPolicy = (r, pid, field, value) => {
    setEdits(prev => {
      const row = prev[r.id] || {};
      const pols = row.policies || {};
      return {
        ...prev,
        [r.id]: { ...row, policies: { ...pols, [pid]: { ...(pols[pid] || {}), [field]: value } } },
      };
    });
  };

  const effectiveSource = (h) => hhTyped(h, "marketing_source") || h.marketing_source || "";

  // ---- what gets sent ------------------------------------------------------
  // The household boxes ride along on every record under that name that still
  // needs them. The server spreads them too, so a household is never half done.
  const recordPayload = (h, r) => {
    const e = edits[r.id] || {};
    const he = hhEdits[h.household] || {};
    const out = { kind: r.kind, id: r.id };
    let any = false;
    const phone = String(he.phone_last4 ?? "").trim();
    if (phone && r.needs_phone) { out.phone_last4 = phone; any = true; }
    const src = String(he.marketing_source ?? "").trim();
    if (src && r.needs_marketing) { out.marketing_source = src; any = true; }
    const ecrm = String(he.ecrm ?? "").trim();
    if (ecrm && r.needs_ecrm) { out.ecrm = ecrm; any = true; }
    const refCust = String(he.referred_by_customer ?? "").trim();
    if (refCust && r.needs_referral) { out.referred_by_customer = refCust; any = true; }
    const refBy = String(he.sourced_by_team_member_id ?? "").trim();
    if (refBy && r.needs_referral) { out.sourced_by_team_member_id = refBy; any = true; }
    const pols = e.policies || {};
    const plist = Object.keys(pols)
      .map(id => {
        const p = pols[id] || {};
        const prem = String(p.issued_premium ?? "").trim();
        const cxl = String(p.canceled_on ?? "").trim();
        if (!prem && !cxl) return null;
        const item = { id };
        if (prem) item.issued_premium = prem;
        const when = String(p.issued_date ?? "").trim();
        if (when) item.issued_date = when;
        // The server applies the premium first, so a chargeback logged in the
        // same save is priced off the number being typed here.
        if (cxl) item.canceled_on = cxl;
        return item;
      })
      .filter(Boolean);
    if (plist.length) { out.policies = plist; any = true; }
    return any ? out : null;
  };

  const householdPayload = (h) => (h.records || []).map(r => recordPayload(h, r)).filter(Boolean);
  const allPayload = () => households.flatMap(householdPayload);

  const send = async (body) => {
    if (!body.length) return;
    setSaving(true);
    setErr("");
    setMsg("");
    const { data, error } = await supabase.rpc("rp_backfill_save", { p_rows: body });
    setSaving(false);
    if (error) { setErr(error.message || "That did not save."); return; }
    const issued = Number(data?.policies_issued || 0);
    const filled = Number(data?.also_filled || 0);
    const saved = Number(data?.rows_saved || 0);
    const canceled = Number(data?.policies_canceled || 0);
    const charged = Number(data?.charged_back || 0);
    setMsg(`Saved ${saved} record${saved === 1 ? "" : "s"}`
      + (issued ? `, ${issued} policy premium${issued === 1 ? "" : "s"}` : "")
      + (canceled ? `, ${canceled} marked canceled (${charged} charged back)` : "")
      + (filled ? `, plus ${filled} more filled in from the same households` : "") + ".");
    load(offset);
  };

  // ---- styles --------------------------------------------------------------
  const input = {
    padding: "5px 7px",
    borderRadius: 6,
    border: `1px solid ${T.slate200}`,
    fontSize: 12,
    color: T.slate900,
    background: T.white,
    boxSizing: "border-box",
    width: "100%",
  };
  const btn = (primary) => ({
    padding: "9px 16px",
    borderRadius: 8,
    border: primary ? "none" : `1px solid ${T.slate200}`,
    background: primary ? T.blue : T.white,
    color: primary ? T.white : T.slate600,
    fontSize: 14,
    fontWeight: 700,
    cursor: "pointer",
    boxSizing: "border-box",
  });
  const sortBtn = {
    border: "none",
    background: "transparent",
    padding: 0,
    font: "inherit",
    fontSize: 12,
    fontWeight: 700,
    color: T.slate500,
    cursor: "pointer",
    whiteSpace: "nowrap",
  };
  const chip = {
    border: "none",
    background: "transparent",
    color: T.blue,
    fontSize: 11,
    fontWeight: 700,
    padding: 0,
    textAlign: "left",
    cursor: "pointer",
  };
  // A household is a row, not a box. One record means one line, nothing more.
  const card = {
    background: T.white,
    borderTop: `1px solid ${T.slate200}`,
    padding: "3px 8px",
    display: "grid",
    gap: 2,
  };
  const line = { display: "flex", flexWrap: "wrap", gap: 6, alignItems: "center", minHeight: 28 };
  const who = { fontSize: 12, fontWeight: 700, color: T.slate900, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", maxWidth: 200 };
  const what = { fontSize: 11, color: T.slate500, whiteSpace: "nowrap" };

  const pending = allPayload().length;

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "baseline", justifyContent: "space-between" }}>
        <div style={{ fontSize: 12, color: T.slate600, maxWidth: 680 }}>
          One line per household. Phone, marketing source and the ECRM link are typed once and land on every record under that name. Per policy: the issued date and premium, and a date to mark it canceled, which charges it back off the premium you are applying. Only what you type gets saved.
        </div>
        <div style={{ fontSize: 13, color: T.slate500 }}>
          {totalHouseholds == null ? "" : searching
            ? `${totalHouseholds} found`
            : `${totalHouseholds} household${totalHouseholds === 1 ? "" : "s"} to go, ${totalRows} record${totalRows === 1 ? "" : "s"}`}
          {offset ? ` \u00b7 from ${offset + 1}` : ""}
        </div>
      </div>

      <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "center" }}>
        <input
          value={box}
          onChange={e => setBox(e.target.value)}
          onKeyDown={e => { if (e.key === "Enter") { e.preventDefault(); runSearch(box.trim()); } }}
          placeholder="Find a customer by name"
          autoComplete="off"
          style={{ ...input, width: 240 }}
        />
        <button type="button" onClick={() => runSearch(box.trim())} disabled={saving || !box.trim()} style={{ ...btn(false), padding: "7px 14px", fontSize: 13 }}>
          Find
        </button>
        {searching ? (
          <button type="button" onClick={() => { setBox(""); runSearch(""); }} disabled={saving} style={{ ...btn(false), padding: "7px 14px", fontSize: 13 }}>
            Back to the list
          </button>
        ) : null}
        <span style={{ marginLeft: "auto", display: "flex", gap: 14, alignItems: "center" }}>
          <span style={{ fontSize: 11, color: T.slate400 }}>Sort</span>
          <button type="button" style={sortBtn} onClick={() => sortBy("date")}>Date{sortArrow("date")}</button>
          <button type="button" style={sortBtn} onClick={() => sortBy("customer")}>Customer{sortArrow("customer")}</button>
          <button type="button" style={sortBtn} onClick={() => sortBy("owner")}>Owner{sortArrow("owner")}</button>
          <button type="button" style={sortBtn} onClick={() => sortBy("missing")}>Missing{sortArrow("missing")}</button>
        </span>
      </div>

      {err ? <div style={{ background: T.redLt, color: T.red, padding: "10px 12px", borderRadius: 8, fontSize: 13 }}>{err}</div> : null}
      {msg ? <div style={{ background: T.greenLt, color: T.green, padding: "10px 12px", borderRadius: 8, fontSize: 13 }}>{msg}</div> : null}

      {loading ? (
        <div style={{ color: T.slate500, fontSize: 13 }}>Loading...</div>
      ) : households.length === 0 ? (
        <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: 18, fontSize: 14, color: T.slate600 }}>
          {searching ? "No records under that name." : "Nothing left to fill in."}
        </div>
      ) : (
        <div style={{ display: "grid", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, overflow: "hidden" }}>
          {households.map(h => {
            const isReferral = effectiveSource(h) === "referral";
            const ready = householdPayload(h).length;
            const records = h.records || [];
            const one = records.length === 1;
            const owners = h.owners || [];
            const manyOwners = owners.length > 1;

            // The household's own boxes. One set, wherever the line ends up.
            const hhBoxes = (
              <>
                {h.needs_phone ? (
                  <input
                    value={hhTyped(h, "phone_last4")}
                    onChange={e => setHh(h, "phone_last4", e.target.value.replace(/\D/g, "").slice(0, 4))}
                    inputMode="numeric"
                    autoComplete="off"
                    placeholder="Phone"
                    title="Phone, last four — fills the whole household"
                    style={{ ...input, width: 74, letterSpacing: 1, fontWeight: 700 }}
                  />
                ) : null}
                {h.needs_marketing ? (
                  <select
                    value={hhTyped(h, "marketing_source")}
                    onChange={e => setHh(h, "marketing_source", e.target.value)}
                    title="Marketing source — fills the whole household"
                    style={{ ...input, width: 150 }}
                  >
                    <option value="">Marketing source</option>
                    {(sources || []).map(s => (
                      <option key={s.source_key} value={s.source_key}>{s.label || s.source_key}</option>
                    ))}
                  </select>
                ) : null}
                {h.needs_ecrm ? (
                  <input
                    value={hhTyped(h, "ecrm")}
                    onChange={e => setHh(h, "ecrm", e.target.value)}
                    autoComplete="off"
                    placeholder="ECRM link"
                    title="ECRM opportunity link — one for the whole household"
                    style={{ ...input, flex: "1 1 140px", minWidth: 110, width: "auto" }}
                  />
                ) : null}
                {isReferral && h.needs_referral ? (
                  <>
                    <input
                      value={hhTyped(h, "referred_by_customer")}
                      onChange={e => setHh(h, "referred_by_customer", e.target.value)}
                      autoComplete="off"
                      placeholder="Referred by"
                      style={{ ...input, width: 130 }}
                    />
                    <select
                      value={hhTyped(h, "sourced_by_team_member_id")}
                      onChange={e => setHh(h, "sourced_by_team_member_id", e.target.value)}
                      style={{ ...input, width: 110 }}
                    >
                      <option value="">Sourced by</option>
                      {(roster || []).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
                    </select>
                  </>
                ) : null}
              </>
            );

            // Every policy in the household that still needs a date or a premium,
            // flattened so they all sit on the household's one line.
            const openPolicies = records.flatMap(r =>
              (r.policies || [])
                .filter(p => !(p.issued_date && p.issued_premium != null && p.canceled_on))
                .map(p => ({ r, p })));

            const polBoxes = ({ r, p }) => {
              const polEdit = ((edits[r.id] || {}).policies || {})[p.id] || {};
              // What is on file is shown, not staged. Only a typed value is sent.
              const premBox = polEdit.issued_premium !== undefined
                ? polEdit.issued_premium
                : (p.issued_premium != null ? String(p.issued_premium) : "");
              const dateBox = polEdit.issued_date !== undefined
                ? polEdit.issued_date
                : (p.issued_date || "");
              return (
                <span key={p.id} style={{ display: "flex", gap: 4, alignItems: "center", flex: "0 1 auto" }}>
                  <span style={{ ...what, color: T.slate400 }} title={`${r.owner || "unassigned"} \u00b7 ${r.on_date} \u00b7 submitted ${Number(p.premium || 0).toLocaleString()}`}>
                    {manyOwners && r.owner ? `${r.owner} ` : ""}{p.product_type}
                  </span>
                  <input
                    value={dateBox}
                    onChange={e => setPolicy(r, p.id, "issued_date", e.target.value)}
                    type="date"
                    title={p.issued_date
                      ? `${p.product_type} issued ${p.issued_date}`
                      : `${p.product_type} \u2014 leave it blank and it issues on the submit date`}
                    style={{ ...input, width: 124, color: p.issued_date || dateBox ? T.slate900 : T.slate400 }}
                  />
                  <input
                    value={premBox}
                    onChange={e => setPolicy(r, p.id, "issued_premium", e.target.value)}
                    inputMode="decimal"
                    autoComplete="off"
                    placeholder="Issued $"
                    title={`${p.product_type} issued premium`}
                    style={{ ...input, width: 88 }}
                  />
                  {p.issued_premium == null && !premBox ? (
                    <button
                      type="button"
                      onClick={() => setPolicy(r, p.id, "issued_premium", String(p.premium ?? ""))}
                      style={chip}
                      title={`${p.product_type} submitted at ${Number(p.premium || 0).toLocaleString()}`}
                    >
                      use {Number(p.premium || 0).toLocaleString()}
                    </button>
                  ) : null}
                  {p.canceled_on ? (
                    <span style={{ ...what, color: T.red, fontWeight: 700 }} title={`${p.product_type} canceled ${p.canceled_on}`}>
                      canceled {p.canceled_on}
                    </span>
                  ) : (
                    <input
                      value={polTyped(r, p.id, "canceled_on")}
                      onChange={e => setPolicy(r, p.id, "canceled_on", e.target.value)}
                      type="date"
                      title={`${p.product_type} \u2014 set a date to mark it canceled and charge it back`}
                      style={{ ...input, width: 124, color: polTyped(r, p.id, "canceled_on") ? T.red : T.slate400 }}
                    />
                  )}
                </span>
              );
            };

            const saveBtn = (
              <button
                type="button"
                onClick={() => send(householdPayload(h))}
                disabled={saving || !ready}
                style={{ ...btn(false), marginLeft: "auto", padding: "4px 10px", fontSize: 12, color: ready ? T.blue : T.slate400 }}
              >
                Save
              </button>
            );

            return (
              <div key={h.household} style={card}>
                <div style={line}>
                  <span style={who}><CustomerName label={h.customer_label} phone4={h.phone_last4} /></span>
                  <span style={what} title={records.map(r => `${r.owner || "unassigned"} \u00b7 ${r.on_date} ${r.detail}`).join("\n")}>
                    {one ? h.last_date : `${records.length} records`}
                  </span>
                  <span style={{ ...what, color: T.slate600, fontWeight: 700 }}
                        title={manyOwners ? "More than one person has records here" : ""}>
                    {owners.length ? owners.join(", ") : "\u2014"}
                  </span>
                  {hhBoxes}
                  {openPolicies.map(polBoxes)}
                  {saveBtn}
                </div>
              </div>
            );
          })}
        </div>
      )}

      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center" }}>
        <button type="button" onClick={() => send(allPayload())} disabled={saving || !pending} style={btn(true)}>
          {saving ? "Saving..." : pending ? `Save ${pending} touched record${pending === 1 ? "" : "s"}` : "Nothing typed yet"}
        </button>
        <button type="button" onClick={() => setOffset(o => o + PAGE)} disabled={saving} style={btn(false)}>
          Skip this page
        </button>
        {offset ? (
          <button type="button" onClick={() => setOffset(0)} disabled={saving} style={btn(false)}>Back to the top</button>
        ) : null}
      </div>
    </div>
  );
}
