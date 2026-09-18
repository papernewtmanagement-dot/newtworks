import { useState, useEffect, useMemo } from "react";
import { supabase } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { T } from "../lib/theme.js";
import { CustomerName } from "../lib/customerAccount.jsx";

// Dashboard > Backfill. The imported history came in without the last four
// phone digits, without the ECRM link on the sale, and on some rows without a
// marketing source, referral detail, or issued premium. This is the list of
// every record still missing one of those, as rows you go down and save.
//
// The rule that matters: nothing is written unless you typed it. A box that
// shows what is already on file is only showing it. The premium the policy was
// submitted at sits under an empty issued premium box as a one-tap suggestion,
// so accepting it is a deliberate tap, never something a Save sweeps up.
//
// Save the row you just did, or save every row you have touched. The phone is
// the household key, so a phone typed on one row fills the other rows on screen
// with the same name, and on save it lands on every record under that name that
// has none. Cancelations never appear here: each takes its phone from the sale
// product it cancels. Issuing goes through rp_mark_issued, same as the To Be
// Issued tab. Reads rp_backfill_queue, writes rp_backfill_save. Owner and
// managers only.

const PAGE = 25;

export default function BackfillTab({ sources = [], roster = [] }) {
  const _vp = useViewport();
  const [rows, setRows] = useState([]);
  const [total, setTotal] = useState(null);
  const [offset, setOffset] = useState(0);
  const [edits, setEdits] = useState({});
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");
  const [box, setBox] = useState("");
  const [search, setSearch] = useState("");
  const [searching, setSearching] = useState(false);

  const load = async (from, q) => {
    setLoading(true);
    setErr("");
    const { data, error } = await supabase.rpc("rp_backfill_queue", {
      p_limit: PAGE,
      p_offset: from,
      p_search: (q ?? search) || null,
    });
    if (error) {
      setErr(error.message || "Could not load the list.");
      setLoading(false);
      return;
    }
    setRows(Array.isArray(data?.rows) ? data.rows : []);
    setTotal(Number(data?.total_rows || 0));
    setSearching(!!data?.searching);
    setEdits({});
    setLoading(false);
  };

  useEffect(() => { load(offset); }, [offset]); // eslint-disable-line react-hooks/exhaustive-deps

  // Pull up a customer by name, whether or not anything is missing on them.
  const runSearch = (q) => {
    setSearch(q);
    setOffset(0);
    load(0, q);
  };

  const srcLabel = useMemo(() => {
    const m = {};
    (sources || []).forEach(s => { m[s.source_key] = s.label || s.source_key; });
    return m;
  }, [sources]);

  const typed = (r, field) => {
    const e = edits[r.id] || {};
    return e[field] !== undefined ? e[field] : "";
  };

  const setField = (r, field, value) => {
    setEdits(prev => ({ ...prev, [r.id]: { ...(prev[r.id] || {}), [field]: value } }));
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

  // A phone belongs to the household, so fill every row on screen with the same
  // name that still has none.
  const setPhone = (r, value) => {
    const four = value.replace(/\D/g, "").slice(0, 4);
    const was = (edits[r.id] || {}).phone_last4;
    setEdits(prev => {
      const next = { ...prev };
      rows.forEach(x => {
        if (x.id === r.id) {
          next[x.id] = { ...(next[x.id] || {}), phone_last4: four };
          return;
        }
        const already = (next[x.id] || {}).phone_last4;
        if (x.customer_label === r.customer_label && !x.phone_last4 && (!already || already === was)) {
          next[x.id] = { ...(next[x.id] || {}), phone_last4: four };
        }
      });
      return next;
    });
  };

  const effectiveSource = (r) => typed(r, "marketing_source") || r.marketing_source || "";

  const rowPayload = (r) => {
    const e = edits[r.id] || {};
    const out = { kind: r.kind, id: r.id };
    let any = false;
    if ((e.phone_last4 || "").trim()) { out.phone_last4 = e.phone_last4.trim(); any = true; }
    if ((e.ecrm || "").trim()) { out.ecrm = e.ecrm.trim(); any = true; }
    if ((e.marketing_source || "").trim()) { out.marketing_source = e.marketing_source.trim(); any = true; }
    if ((e.referred_by_customer || "").trim()) { out.referred_by_customer = e.referred_by_customer.trim(); any = true; }
    if ((e.sourced_by_team_member_id || "").trim()) { out.sourced_by_team_member_id = e.sourced_by_team_member_id.trim(); any = true; }
    const pols = e.policies || {};
    const plist = Object.keys(pols)
      .map(id => {
        const p = pols[id] || {};
        const prem = String(p.issued_premium ?? "").trim();
        if (!prem) return null;
        const item = { id, issued_premium: prem };
        const when = String(p.issued_date ?? "").trim();
        if (when) item.issued_date = when;
        return item;
      })
      .filter(Boolean);
    if (plist.length) { out.policies = plist; any = true; }
    return any ? out : null;
  };

  const allPayload = () => rows.map(rowPayload).filter(Boolean);

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
    setMsg(`Saved ${saved} record${saved === 1 ? "" : "s"}${issued ? `, ${issued} policy premium${issued === 1 ? "" : "s"}` : ""}${filled ? `, plus ${filled} more filled in from the same households` : ""}.`);
    load(offset);
  };

  const th = { textAlign: "left", fontSize: 11, fontWeight: 700, color: T.slate500, padding: "6px 8px", whiteSpace: "nowrap" };
  const td = { padding: "6px 8px", borderTop: `1px solid ${T.slate200}`, verticalAlign: "top", fontSize: 13, color: T.slate700 };
  const input = {
    padding: "7px 9px",
    borderRadius: 7,
    border: `1px solid ${T.slate200}`,
    fontSize: 13,
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

  const pending = allPayload().length;

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "baseline", justifyContent: "space-between" }}>
        <div style={{ fontSize: 13, color: T.slate600, maxWidth: 620 }}>
          Older records still missing something. Only what you type gets saved. Save a row on its own, or save everything you have touched. A phone fills the other rows with the same name.
        </div>
        <div style={{ fontSize: 13, color: T.slate500 }}>
          {total == null ? "" : searching ? `${total} found` : `${total} to go`}{offset ? ` · from ${offset + 1}` : ""}
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
      </div>

      {err ? <div style={{ background: T.redLt, color: T.red, padding: "10px 12px", borderRadius: 8, fontSize: 13 }}>{err}</div> : null}
      {msg ? <div style={{ background: T.greenLt, color: T.green, padding: "10px 12px", borderRadius: 8, fontSize: 13 }}>{msg}</div> : null}

      {loading ? (
        <div style={{ color: T.slate500, fontSize: 14 }}>Loading...</div>
      ) : rows.length === 0 ? (
        <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: 18, fontSize: 14, color: T.slate600 }}>
          {searching ? "No records under that name." : "Nothing left to fill in."}
        </div>
      ) : (
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12 }}>
          <table style={{ borderCollapse: "collapse", width: "100%", minWidth: 1120 }}>
            <thead>
              <tr>
                <th style={th}>Date</th>
                <th style={th}>Customer</th>
                <th style={{ ...th, width: 90 }}>Phone</th>
                <th style={{ ...th, minWidth: 210 }}>ECRM link</th>
                <th style={{ ...th, minWidth: 165 }}>Marketing source</th>
                <th style={{ ...th, minWidth: 210 }}>Policies</th>
                <th style={th}></th>
              </tr>
            </thead>
            <tbody>
              {rows.map(r => {
                const isReferral = effectiveSource(r) === "referral";
                const rowReady = !!rowPayload(r);
                return (
                  <tr key={`${r.kind}-${r.id}`}>
                    <td style={{ ...td, whiteSpace: "nowrap", color: T.slate500 }}>
                      {r.on_date}
                      {r.kind === "quote" ? <div style={{ fontSize: 11 }}>quote</div> : null}
                    </td>
                    <td style={{ ...td, fontWeight: 600, color: T.slate900, whiteSpace: "nowrap" }}><CustomerName label={r.customer_label} phone4={r.phone_last4} /></td>
                    <td style={td}>
                      {r.phone_last4 ? (
                        <span style={{ color: T.slate500 }}>{r.phone_last4}</span>
                      ) : (
                        <input
                          value={typed(r, "phone_last4")}
                          onChange={e => setPhone(r, e.target.value)}
                          inputMode="numeric"
                          autoComplete="off"
                          placeholder="0000"
                          style={{ ...input, letterSpacing: 2, fontWeight: 700 }}
                        />
                      )}
                    </td>
                    <td style={td}>
                      {r.kind === "quote" ? (
                        <span style={{ color: T.slate500, fontSize: 12 }}>not needed</span>
                      ) : r.ecrm ? (
                        <span style={{ color: T.slate500, fontSize: 12 }}>on file</span>
                      ) : (
                        <input
                          value={typed(r, "ecrm")}
                          onChange={e => setField(r, "ecrm", e.target.value)}
                          placeholder="https://"
                          autoComplete="off"
                          style={input}
                        />
                      )}
                    </td>
                    <td style={td}>
                      {r.needs_marketing ? (
                        <select
                          value={typed(r, "marketing_source")}
                          onChange={e => setField(r, "marketing_source", e.target.value)}
                          style={input}
                        >
                          <option value="">Pick one</option>
                          {(sources || []).map(s => (
                            <option key={s.source_key} value={s.source_key}>{s.label || s.source_key}</option>
                          ))}
                        </select>
                      ) : (
                        <span style={{ color: T.slate500, fontSize: 12 }}>{srcLabel[r.marketing_source] || r.marketing_source || ""}</span>
                      )}
                      {isReferral && !r.referred_by_customer && !r.sourced_by_team_member_id ? (
                        <div style={{ display: "grid", gap: 5, marginTop: 6 }}>
                          <input
                            value={typed(r, "referred_by_customer")}
                            onChange={e => setField(r, "referred_by_customer", e.target.value)}
                            placeholder="Referred by which customer"
                            autoComplete="off"
                            style={input}
                          />
                          <select
                            value={typed(r, "sourced_by_team_member_id")}
                            onChange={e => setField(r, "sourced_by_team_member_id", e.target.value)}
                            style={input}
                          >
                            <option value="">Sourced by</option>
                            {(roster || []).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
                          </select>
                        </div>
                      ) : null}
                    </td>
                    <td style={td}>
                      {(r.policies || []).length ? (
                        <div style={{ display: "grid", gap: 10 }}>
                          {r.policies.map(p => {
                            const polEdit = ((edits[r.id] || {}).policies || {})[p.id] || {};
                            // What is on file is shown, not staged. Only a typed value is sent.
                            const premBox = polEdit.issued_premium !== undefined
                              ? polEdit.issued_premium
                              : (p.issued_premium != null ? String(p.issued_premium) : "");
                            return (
                              <div key={p.id} style={{ display: "grid", gap: 3 }}>
                                <span style={{ fontSize: 11, color: T.slate500 }}>
                                  {p.product_type} · submitted ${Number(p.premium || 0).toLocaleString()}
                                </span>
                                {!p.issued_date ? (
                                  <input
                                    value={polTyped(r, p.id, "issued_date")}
                                    onChange={e => setPolicy(r, p.id, "issued_date", e.target.value)}
                                    type="date"
                                    style={input}
                                  />
                                ) : null}
                                <input
                                  value={premBox}
                                  onChange={e => setPolicy(r, p.id, "issued_premium", e.target.value)}
                                  inputMode="decimal"
                                  autoComplete="off"
                                  placeholder={p.issued_date ? "Issued premium" : "Issued premium once it issues"}
                                  style={input}
                                />
                                {p.issued_premium == null && !premBox ? (
                                  <button
                                    type="button"
                                    onClick={() => setPolicy(r, p.id, "issued_premium", String(p.premium ?? ""))}
                                    style={chip}
                                  >
                                    use {Number(p.premium || 0).toLocaleString()}
                                  </button>
                                ) : null}
                              </div>
                            );
                          })}
                        </div>
                      ) : (
                        <span style={{ color: T.slate500, fontSize: 12 }}>—</span>
                      )}
                    </td>
                    <td style={td}>
                      <button
                        type="button"
                        onClick={() => send([rowPayload(r)].filter(Boolean))}
                        disabled={saving || !rowReady}
                        style={{ ...btn(false), padding: "7px 12px", fontSize: 13, color: rowReady ? T.blue : T.slate500 }}
                      >
                        Save
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center" }}>
        <button type="button" onClick={() => send(allPayload())} disabled={saving || !pending} style={btn(true)}>
          {saving ? "Saving..." : pending ? `Save ${pending} touched row${pending === 1 ? "" : "s"}` : "Nothing typed yet"}
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
