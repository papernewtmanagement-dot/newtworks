import { useState, useEffect, useRef } from "react";
import { supabase } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { T } from "../lib/theme.js";

// Dashboard > Backfill. The imported history came in without the last four
// phone digits, without an ECRM link on the sale, and on some rows without a
// marketing source. This fills those in, one household at a time: the phone is
// the household key, so it lands on every record under that name at once.
// Type four digits, press Enter, next household. Owner and managers only.
// Reads rp_backfill_queue, writes rp_backfill_save. Nothing here touches
// policies, points, or where a record came from.

const BATCH = 40;

export default function BackfillTab({ sources = [] }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "0" : "0";
  const [queue, setQueue] = useState([]);
  const [total, setTotal] = useState(null);
  const [i, setI] = useState(0);
  const [loading, setLoading] = useState(true);
  const [exhausted, setExhausted] = useState(false);
  const [err, setErr] = useState("");
  const [saving, setSaving] = useState(false);
  const [done, setDone] = useState(0);
  const [phone, setPhone] = useState("");
  const [src, setSrc] = useState("");
  const [links, setLinks] = useState({});
  const [showLinks, setShowLinks] = useState(false);
  const skipped = useRef(new Set());
  const box = useRef(null);

  const load = async () => {
    setLoading(true);
    setErr("");
    const { data, error } = await supabase.rpc("rp_backfill_queue", { p_limit: BATCH, p_offset: 0 });
    if (error) {
      setErr(error.message || "Could not load the list.");
      setLoading(false);
      return;
    }
    const all = Array.isArray(data?.households) ? data.households : [];
    const left = all.filter(h => !skipped.current.has(h.customer_label));
    setTotal(Number(data?.total_households || 0));
    setQueue(left);
    setI(0);
    setExhausted(left.length === 0);
    setLoading(false);
  };

  useEffect(() => { load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const current = queue[i] || null;
  const label = current?.customer_label || "";

  useEffect(() => {
    setPhone("");
    setSrc("");
    setLinks({});
    setShowLinks(false);
    if (box.current) box.current.focus();
  }, [label]);

  useEffect(() => {
    if (!loading && !exhausted && queue.length > 0 && i >= queue.length) load();
  }, [i, queue.length, loading, exhausted]); // eslint-disable-line react-hooks/exhaustive-deps

  const records = Array.isArray(current?.records) ? current.records : [];
  const needsPhone = records.some(r => r?.needs_phone);
  const needsMarketing = records.some(r => r?.needs_marketing);
  const saleLinks = records.filter(r => r?.kind === "sale" && r?.needs_ecrm);

  const next = () => setI(n => n + 1);

  const skip = () => {
    if (label) skipped.current.add(label);
    next();
  };

  const save = async () => {
    if (!current || saving) return;
    const ecrm = Object.keys(links)
      .filter(id => (links[id] || "").trim())
      .map(id => ({ id, url: (links[id] || "").trim() }));
    if (!phone.trim() && !src && ecrm.length === 0) { next(); return; }
    setSaving(true);
    setErr("");
    const payload = { customer_label: label };
    if (phone.trim()) payload.phone_last4 = phone.trim();
    if (src) payload.marketing_source = src;
    if (ecrm.length) payload.ecrm = ecrm;
    const { data, error } = await supabase.rpc("rp_backfill_save", { p_payload: payload });
    setSaving(false);
    if (error) { setErr(error.message || "That did not save."); return; }
    if (data?.ok) {
      setDone(d => d + 1);
      setTotal(t => (Number.isFinite(t) && t > 0 ? t - 1 : t));
      next();
    }
  };

  const onKey = (e) => {
    if (e.key === "Enter") { e.preventDefault(); save(); }
  };

  const card = {
    background: T.white,
    border: `1px solid ${T.slate200}`,
    borderRadius: 12,
    padding: _vp.isPhone ? 14 : 18,
    boxSizing: "border-box",
  };
  const input = {
    padding: "10px 12px",
    borderRadius: 8,
    border: `1px solid ${T.slate200}`,
    fontSize: 15,
    color: T.slate900,
    background: T.white,
    boxSizing: "border-box",
  };
  const btn = (primary) => ({
    padding: "10px 16px",
    borderRadius: 8,
    border: primary ? "none" : `1px solid ${T.slate200}`,
    background: primary ? T.blue : T.white,
    color: primary ? T.white : T.slate600,
    fontSize: 14,
    fontWeight: 700,
    cursor: "pointer",
    boxSizing: "border-box",
  });

  return (
    <div style={{ padding: _pad, display: "grid", gap: 14, maxWidth: 640 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "baseline", justifyContent: "space-between" }}>
        <div style={{ fontSize: 13, color: T.slate600 }}>
          Older records that are still missing something. The phone goes on every record under the same name.
        </div>
        <div style={{ fontSize: 13, color: T.slate500 }}>
          {total == null ? "" : `${total} left`}{done ? ` · ${done} done` : ""}
        </div>
      </div>

      {err ? (
        <div style={{ background: T.redLt, color: T.red, padding: "10px 12px", borderRadius: 8, fontSize: 13 }}>{err}</div>
      ) : null}

      {loading ? (
        <div style={{ color: T.slate500, fontSize: 14 }}>Loading...</div>
      ) : !current ? (
        <div style={{ ...card, color: T.slate600, fontSize: 14 }}>
          {exhausted && total ? "Everything left in the list was skipped this session. Reload the tab to see them again." : "Nothing left to fill in."}
        </div>
      ) : (
        <div style={card}>
          <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900 }}>{label}</div>
          <div style={{ display: "grid", gap: 4, margin: "8px 0 14px" }}>
            {records.map(r => (
              <div key={`${r.kind}-${r.id}`} style={{ fontSize: 12, color: T.slate500 }}>
                {r.on_date} · {r.detail}
                {r.needs_phone ? " · needs phone" : ""}
                {r.needs_marketing ? " · needs marketing source" : ""}
                {r.needs_ecrm ? " · needs ECRM link" : ""}
              </div>
            ))}
          </div>

          <div style={{ display: "grid", gap: 12 }}>
            {needsPhone ? (
              <label style={{ display: "grid", gap: 5 }}>
                <span style={{ fontSize: 12, fontWeight: 700, color: T.slate600 }}>Phone, last four digits</span>
                <input
                  ref={box}
                  value={phone}
                  onChange={e => setPhone(e.target.value.replace(/\D/g, "").slice(0, 4))}
                  onKeyDown={onKey}
                  inputMode="numeric"
                  autoComplete="off"
                  placeholder="0000"
                  style={{ ...input, width: 120, fontSize: 20, letterSpacing: 3, fontWeight: 700 }}
                />
              </label>
            ) : null}

            {needsMarketing ? (
              <label style={{ display: "grid", gap: 5 }}>
                <span style={{ fontSize: 12, fontWeight: 700, color: T.slate600 }}>Marketing source</span>
                <select value={src} onChange={e => setSrc(e.target.value)} style={{ ...input, maxWidth: 320 }}>
                  <option value="">Pick one</option>
                  {(sources || []).map(s => (
                    <option key={s.source_key} value={s.source_key}>{s.label || s.source_key}</option>
                  ))}
                </select>
              </label>
            ) : null}

            {saleLinks.length ? (
              showLinks ? (
                <div style={{ display: "grid", gap: 8 }}>
                  {saleLinks.map(r => (
                    <label key={r.id} style={{ display: "grid", gap: 4 }}>
                      <span style={{ fontSize: 12, fontWeight: 700, color: T.slate600 }}>ECRM link · {r.on_date}</span>
                      <input
                        value={links[r.id] || ""}
                        onChange={e => setLinks(m => ({ ...m, [r.id]: e.target.value }))}
                        placeholder="https://"
                        style={input}
                      />
                    </label>
                  ))}
                </div>
              ) : (
                <button type="button" onClick={() => setShowLinks(true)} style={{ ...btn(false), justifySelf: "start", fontWeight: 600, fontSize: 13 }}>
                  Add ECRM {saleLinks.length > 1 ? "links" : "link"}
                </button>
              )
            ) : null}
          </div>

          <div style={{ display: "flex", flexWrap: "wrap", gap: 10, marginTop: 16, alignItems: "center" }}>
            <button type="button" onClick={save} disabled={saving} style={btn(true)}>
              {saving ? "Saving..." : "Save and next"}
            </button>
            <button type="button" onClick={skip} style={btn(false)}>Skip</button>
            <span style={{ fontSize: 12, color: T.slate500 }}>Enter saves and moves on.</span>
          </div>
        </div>
      )}
    </div>
  );
}
