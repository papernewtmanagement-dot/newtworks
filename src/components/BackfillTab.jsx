import { useState, useEffect, useMemo } from "react";
import { supabase } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { T } from "../lib/theme.js";

// Dashboard > Backfill. The imported history came in without the last four
// phone digits, without the ECRM link on the sale, and on some rows without a
// marketing source or the referral detail. This is the list of every record
// still missing one of those, as rows you go straight down and save as a batch.
// The phone is the household key, so a phone typed on one row fills the other
// rows on screen with the same name, and on save it lands on every record
// under that name that has none. Cancelations never appear here: each one is
// matched to the sale product it cancels, so it takes its phone from that sale.
// Reads rp_backfill_queue, writes rp_backfill_save. Nothing here touches
// policies, points, or where a record came from. Owner and managers only.

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

  const load = async (from) => {
    setLoading(true);
    setErr("");
    const { data, error } = await supabase.rpc("rp_backfill_queue", { p_limit: PAGE, p_offset: from });
    if (error) {
      setErr(error.message || "Could not load the list.");
      setLoading(false);
      return;
    }
    const list = Array.isArray(data?.rows) ? data.rows : [];
    // The issued premium starts at the premium the policy was submitted at.
    const seed = {};
    list.forEach(r => {
      if (Array.isArray(r.policies) && r.policies.length) {
        const pol = {};
        r.policies.forEach(p => { pol[p.id] = p.premium == null ? "" : String(p.premium); });
        seed[r.id] = { policies: pol };
      }
    });
    setRows(list);
    setTotal(Number(data?.total_rows || 0));
    setEdits(seed);
    setLoading(false);
  };

  useEffect(() => { load(offset); }, [offset]); // eslint-disable-line react-hooks/exhaustive-deps

  const srcLabel = useMemo(() => {
    const m = {};
    (sources || []).forEach(s => { m[s.source_key] = s.label || s.source_key; });
    return m;
  }, [sources]);

  const val = (r, field) => {
    const e = edits[r.id] || {};
    return e[field] !== undefined ? e[field] : "";
  };

  const setField = (r, field, value) => {
    setEdits(prev => ({ ...prev, [r.id]: { ...(prev[r.id] || {}), [field]: value } }));
  };

  const polVal = (r, pid) => {
    const pol = (edits[r.id] || {}).policies || {};
    return pol[pid] !== undefined ? pol[pid] : "";
  };

  const setPolicy = (r, pid, value) => {
    setEdits(prev => ({
      ...prev,
      [r.id]: { ...(prev[r.id] || {}), policies: { ...((prev[r.id] || {}).policies || {}), [pid]: value } },
    }));
  };

  // A phone belongs to the household, so fill every row on screen with the
  // same name that still has none.
  const setPhone = (r, value) => {
    const four = value.replace(/\D/g, "").slice(0, 4);
    setEdits(prev => {
      const next = { ...prev };
      rows.forEach(x => {
        const already = (next[x.id] || {}).phone_last4;
        const sameName = x.customer_label === r.customer_label;
        if (x.id === r.id) {
          next[x.id] = { ...(next[x.id] || {}), phone_last4: four };
        } else if (sameName && !x.phone_last4 && (!already || already === (prev[r.id] || {}).phone_last4)) {
          next[x.id] = { ...(next[x.id] || {}), phone_last4: four };
        }
      });
      return next;
    });
  };

  const effectiveSource = (r) => val(r, "marketing_source") || r.marketing_source || "";

  const payload = () => rows.map(r => {
    const e = edits[r.id] || {};
    const out = { kind: r.kind, id: r.id };
    let any = false;
    if ((e.phone_last4 || "").trim() && e.phone_last4 !== r.phone_last4) { out.phone_last4 = e.phone_last4.trim(); any = true; }
    if ((e.ecrm || "").trim()) { out.ecrm = e.ecrm.trim(); any = true; }
    if ((e.marketing_source || "").trim()) { out.marketing_source = e.marketing_source.trim(); any = true; }
    if ((e.referred_by_customer || "").trim()) { out.referred_by_customer = e.referred_by_customer.trim(); any = true; }
    if ((e.sourced_by_team_member_id || "").trim()) { out.sourced_by_team_member_id = e.sourced_by_team_member_id.trim(); any = true; }
    const pol = e.policies || {};
    const plist = Object.keys(pol)
      .filter(id => String(pol[id] ?? "").trim() !== "")
      .map(id => ({ id, issued_premium: String(pol[id]).trim() }));
    if (plist.length) { out.policies = plist; any = true; }
    return any ? out : null;
  }).filter(Boolean);

  const save = async () => {
    const body = payload();
    if (!body.length) return;
    setSaving(true);
    setErr("");
    setMsg("");
    const { data, error } = await supabase.rpc("rp_backfill_save", { p_rows: body });
    setSaving(false);
    if (error) { setErr(error.message || "That did not save."); return; }
    const filled = Number(data?.also_filled || 0);
    const issued = Number(data?.policies_issued || 0);
    setMsg(`Saved ${Number(data?.rows_saved || 0)} record${Number(data?.rows_saved) === 1 ? "" : "s"}${issued ? `, ${issued} issued premium${issued === 1 ? "" : "s"}` : ""}${filled ? `, plus ${filled} more filled in from the same households` : ""}.`);
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

  const pending = payload().length;

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "baseline", justifyContent: "space-between" }}>
        <div style={{ fontSize: 13, color: T.slate600, maxWidth: 560 }}>
          Older records still missing something. Fill what you can down the rows and save the batch. A phone fills the other rows with the same name. Issued premium starts at what the policy was submitted at.
        </div>
        <div style={{ fontSize: 13, color: T.slate500 }}>
          {total == null ? "" : `${total} to go`}{offset ? ` · from ${offset + 1}` : ""}
        </div>
      </div>

      {err ? <div style={{ background: T.redLt, color: T.red, padding: "10px 12px", borderRadius: 8, fontSize: 13 }}>{err}</div> : null}
      {msg ? <div style={{ background: T.greenLt, color: T.green, padding: "10px 12px", borderRadius: 8, fontSize: 13 }}>{msg}</div> : null}

      {loading ? (
        <div style={{ color: T.slate500, fontSize: 14 }}>Loading...</div>
      ) : rows.length === 0 ? (
        <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: 18, fontSize: 14, color: T.slate600 }}>
          Nothing left to fill in.
        </div>
      ) : (
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12 }}>
          <table style={{ borderCollapse: "collapse", width: "100%", minWidth: 1040 }}>
            <thead>
              <tr>
                <th style={th}>Date</th>
                <th style={th}>Customer</th>
                <th style={th}>What</th>
                <th style={{ ...th, width: 90 }}>Phone</th>
                <th style={{ ...th, minWidth: 220 }}>ECRM link</th>
                <th style={{ ...th, minWidth: 170 }}>Marketing source</th>
                <th style={{ ...th, minWidth: 130 }}>Issued premium</th>
              </tr>
            </thead>
            <tbody>
              {rows.map(r => {
                const isReferral = effectiveSource(r) === "referral";
                return (
                  <tr key={`${r.kind}-${r.id}`}>
                    <td style={{ ...td, whiteSpace: "nowrap", color: T.slate500 }}>{r.on_date}</td>
                    <td style={{ ...td, fontWeight: 600, color: T.slate900, whiteSpace: "nowrap" }}>{r.customer_label}</td>
                    <td style={{ ...td, color: T.slate500, fontSize: 12 }}>
                      {r.kind === "quote" ? "quote" : r.detail}
                    </td>
                    <td style={td}>
                      {r.phone_last4 ? (
                        <span style={{ color: T.slate500 }}>{r.phone_last4}</span>
                      ) : (
                        <input
                          value={val(r, "phone_last4")}
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
                          value={val(r, "ecrm")}
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
                          value={val(r, "marketing_source")}
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
                            value={val(r, "referred_by_customer")}
                            onChange={e => setField(r, "referred_by_customer", e.target.value)}
                            placeholder="Referred by which customer"
                            autoComplete="off"
                            style={input}
                          />
                          <select
                            value={val(r, "sourced_by_team_member_id")}
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
                        <div style={{ display: "grid", gap: 6 }}>
                          {r.policies.map(p => (
                            <label key={p.id} style={{ display: "grid", gap: 2 }}>
                              <span style={{ fontSize: 11, color: T.slate500 }}>{p.product_type}</span>
                              <input
                                value={polVal(r, p.id)}
                                onChange={e => setPolicy(r, p.id, e.target.value)}
                                inputMode="decimal"
                                autoComplete="off"
                                style={input}
                              />
                            </label>
                          ))}
                        </div>
                      ) : (
                        <span style={{ color: T.slate500, fontSize: 12 }}>—</span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center" }}>
        <button type="button" onClick={save} disabled={saving || !pending} style={btn(true)}>
          {saving ? "Saving..." : pending ? `Save ${pending} row${pending === 1 ? "" : "s"}` : "Nothing to save yet"}
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
