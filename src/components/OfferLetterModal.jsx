import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";

// Offer letter form. Opens when a candidate is moved to the Offer stage.
//
// It reads two tables:
//   role_pay_ranges        — the standing pay the agency works from, so the
//                            amount box arrives with the right band already
//                            showing instead of being typed from memory.
//   offer_letter_templates — the letter wording, with fill-in fields wrapped
//                            in double braces.
//
// It writes the chosen terms and the finished letter back onto the candidate
// row (the offer_* columns added 2026-08-20), so the exact wording that went
// out can be read back later.

const AGENCY_NAME    = "Peter Story State Farm";
const EMPLOYER_NAME  = "PaperNewt LLC";
const AGENT_NAME     = "Peter Story";
const AGENCY_ADDRESS = "28120 US Hwy 281 N, Suite 125\nSan Antonio, TX 78260";

const money = (n, period) => {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  if (period === "hour") return `$${v.toFixed(2)}`;
  return `$${Math.round(v).toLocaleString("en-US")}`;
};

const longDate = (iso) => {
  if (!iso) return "";
  const d = new Date(`${iso}T12:00:00`);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" });
};

const todayIso = () => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};

const addDaysIso = (days) => {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};

// Guess which pay row fits from whatever the posting called the job. Only a
// starting point — the role picker is right there and overrides it.
function guessRoleKey(positionText) {
  const p = String(positionText || "").toLowerCase();
  if (p.includes("life")) return "life_specialist";
  if (p.includes("recept") || p.includes("service") || p.includes("retention") || p.includes("account manager")) return "retention";
  if (p.includes("sales") || p.includes("account rep") || p.includes("telemarket") || p.includes("account associate")) return "sales";
  return "";
}

function defaultLicenseClause(row) {
  if (!row) {
    return "Any licence this position requires must be in place before you speak with a customer about coverage.";
  }
  if (row.requires_license_pc && row.requires_license_lh) {
    return "This position requires both an active Texas Property and Casualty licence and an active Texas Life and Health licence. Until both are issued you may not quote, bind or discuss coverage with a customer. We will support you through the licensing process.";
  }
  if (row.requires_license_pc) {
    return "This position requires an active Texas Property and Casualty licence. Until it is issued you may not quote, bind or discuss coverage with a customer. We will support you through the licensing process, and your first weeks will be spent preparing for it.";
  }
  return "You will start unlicensed. Until your Texas Property and Casualty licence is issued you may not quote, bind or discuss coverage with a customer, and your pay moves up a step once it is in hand. We will support you through the licensing process.";
}

function fillTemplate(body, fields) {
  return String(body || "").replace(/\{\{\s*([a-z0-9_]+)\s*\}\}/gi, (whole, key) => {
    const v = fields[key];
    return v == null || v === "" ? whole : String(v);
  });
}

export default function OfferLetterModal({ candidate, onClose, onSaved }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "14px" : "22px";

  const [payRows, setPayRows]     = useState([]);
  const [template, setTemplate]   = useState(null);
  const [loading, setLoading]     = useState(true);
  const [loadError, setLoadError] = useState(null);
  const [saving, setSaving]       = useState(false);
  const [copied, setCopied]       = useState(false);
  const [showLetter, setShowLetter] = useState(false);

  const [jobTitle, setJobTitle]       = useState(candidate?.offer_job_title || candidate?.position || "");
  const [roleKey, setRoleKey]         = useState(candidate?.offer_role_key || "");
  const [tierKey, setTierKey]         = useState("");
  const [payType, setPayType]         = useState(candidate?.offer_pay_type || "");
  const [amount, setAmount]           = useState(candidate?.offer_pay_amount != null ? String(candidate.offer_pay_amount) : "");
  const [startDate, setStartDate]     = useState(candidate?.offer_start_date || addDaysIso(14));
  const [respondBy, setRespondBy]     = useState(candidate?.offer_respond_by || addDaysIso(5));
  const [reportsTo, setReportsTo]     = useState(candidate?.offer_reports_to || "Peter Story, Agent");
  const [licenseClause, setLicenseClause] = useState("");
  const [licenseTouched, setLicenseTouched] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      const [payRes, tplRes] = await Promise.all([
        supabase.from("role_pay_ranges").select("*")
          .eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("offer_letter_templates").select("*")
          .eq("agency_id", AGENCY_ID).eq("template_key", "standard").eq("is_active", true).maybeSingle(),
      ]);
      if (cancelled) return;
      if (payRes.error) setLoadError(payRes.error.message);
      else if (tplRes.error) setLoadError(tplRes.error.message);
      setPayRows(payRes.data || []);
      setTemplate(tplRes.data || null);
      setLoading(false);
    })();
    return () => { cancelled = true; };
  }, []);

  // Pick a sensible starting role once the pay rows land, unless the candidate
  // already has an offer saved.
  useEffect(() => {
    if (roleKey || !payRows.length) return;
    const guess = guessRoleKey(candidate?.position);
    if (guess && payRows.some(r => r.role_key === guess)) setRoleKey(guess);
  }, [payRows]); // eslint-disable-line react-hooks/exhaustive-deps

  const roles = useMemo(() => {
    const seen = new Map();
    (payRows || []).forEach(r => { if (!seen.has(r.role_key)) seen.set(r.role_key, r.role_label); });
    return Array.from(seen, ([key, label]) => ({ key, label }));
  }, [payRows]);

  const tiers = useMemo(
    () => (payRows || []).filter(r => r.role_key === roleKey),
    [payRows, roleKey]
  );

  // Keep the tier valid whenever the role changes.
  useEffect(() => {
    if (!tiers.length) { setTierKey(""); return; }
    if (!tiers.some(t => t.tier_key === tierKey)) setTierKey(tiers[0].tier_key);
  }, [tiers]); // eslint-disable-line react-hooks/exhaustive-deps

  const payRow = useMemo(
    () => tiers.find(t => t.tier_key === tierKey) || null,
    [tiers, tierKey]
  );

  // Pay type and amount follow the chosen band unless already typed over.
  useEffect(() => {
    if (!payRow) return;
    setPayType(payRow.pay_type);
    setAmount(prev => (prev === "" ? String(Number(payRow.amount_min)) : prev));
  }, [payRow?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (licenseTouched) return;
    setLicenseClause(defaultLicenseClause(payRow));
  }, [payRow?.id, licenseTouched]); // eslint-disable-line react-hooks/exhaustive-deps

  const payPeriod = payType === "hourly" ? "hour" : "year";

  const outOfBand = useMemo(() => {
    if (!payRow || amount === "") return null;
    const v = Number(amount);
    if (!Number.isFinite(v)) return null;
    if (payRow.pay_type !== payType) return "type";
    if (v < Number(payRow.amount_min)) return "below";
    if (v > Number(payRow.amount_max)) return "above";
    return null;
  }, [payRow, amount, payType]);

  const payLine = useMemo(() => {
    if (amount === "") return "";
    if (payType === "hourly") {
      return `You will be paid **${money(amount, "hour")} per hour**, on an hourly basis, for hours actually worked.`;
    }
    return `Your base salary will be **${money(amount, "year")} per year**.`;
  }, [amount, payType]);

  const fullName = [candidate?.first_name, candidate?.last_name].filter(Boolean).join(" ")
    || candidate?.candidate_name || "";

  const letter = useMemo(() => {
    if (!template?.body_md) return "";
    return fillTemplate(template.body_md, {
      employer_name:        EMPLOYER_NAME,
      agency_name:          AGENCY_NAME,
      agency_address:       AGENCY_ADDRESS,
      agent_name:           AGENT_NAME,
      offer_date:           longDate(todayIso()),
      candidate_name:       fullName,
      candidate_first_name: candidate?.first_name || fullName.split(" ")[0] || "",
      job_title:            jobTitle,
      reports_to:           reportsTo,
      start_date:           longDate(startDate),
      respond_by:           longDate(respondBy),
      pay_line:             payLine,
      offer_amount:         money(amount, payType === "hourly" ? "hour" : "year"),
      license_clause:       licenseClause,
    });
  }, [template, fullName, candidate, jobTitle, reportsTo, startDate, respondBy, payLine, licenseClause]);

  const stillBlank = useMemo(() => {
    const found = letter.match(/\{\{\s*([a-z0-9_]+)\s*\}\}/gi) || [];
    return Array.from(new Set(found.map(s => s.replace(/[{}\s]/g, ""))));
  }, [letter]);

  const canSave = Boolean(jobTitle) && Boolean(payType) && amount !== ""
    && Number.isFinite(Number(amount)) && Number(amount) > 0
    && Boolean(startDate) && !saving;

  const save = async () => {
    if (!candidate?.id || !canSave) return;
    setSaving(true);
    const nowIso = new Date().toISOString();
    const { error } = await supabase
      .from("hiring_candidates")
      .update({
        status:            "offer",
        status_updated_at: nowIso,
        offer_job_title:   jobTitle,
        offer_role_key:    roleKey || null,
        offer_pay_type:    payType,
        offer_pay_amount:  Number(amount),
        offer_pay_period:  payPeriod,
        offer_start_date:  startDate || null,
        offer_respond_by:  respondBy || null,
        offer_reports_to:  reportsTo || null,
        offer_letter_body: letter,
        offer_created_at:  candidate?.offer_created_at || nowIso,
      })
      .eq("id", candidate.id);
    setSaving(false);
    if (error) { alert("Saving the offer failed: " + error.message); return; }
    if (typeof onSaved === "function") onSaved();
  };

  const copyLetter = async () => {
    try {
      await navigator.clipboard.writeText(letter);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch { /* clipboard blocked — the text is on screen to select by hand */ }
  };

  const label = { fontSize: 11, fontWeight: 700, color: T.slate600, marginBottom: 4, display: "block" };
  const input = {
    width: "100%", boxSizing: "border-box", padding: "8px 10px", fontSize: 13,
    border: `1px solid ${T.slate200}`, borderRadius: 8, color: T.slate900, background: T.white,
  };

  return (
    <div
      onClick={onClose}
      style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.5)", display: "flex",
               alignItems: "center", justifyContent: "center", zIndex: 1000, padding: _vp.isPhone ? 8 : 20 }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{ background: T.white, borderRadius: 14, padding: _pad, width: "100%", maxWidth: 720,
                 maxHeight: "92vh", overflowY: "auto", boxSizing: "border-box",
                 boxShadow: "0 20px 60px rgba(0,0,0,0.3)" }}
      >
        <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between",
                      gap: 10, flexWrap: "wrap", marginBottom: 4 }}>
          <div>
            <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900, letterSpacing: "-0.01em" }}>
              Offer letter
            </div>
            <div style={{ fontSize: 12, color: T.slate500, marginTop: 2 }}>
              {fullName || "Candidate"} · moving to the Offer stage
            </div>
          </div>
          <button onClick={onClose} style={{ background: "none", border: "none", fontSize: 20,
                                             color: T.slate400, cursor: "pointer", lineHeight: 1 }}>×</button>
        </div>

        {loading && <div style={{ fontSize: 13, color: T.slate500, padding: "20px 0" }}>Loading pay bands and letter…</div>}
        {loadError && (
          <div style={{ fontSize: 12, color: T.red, background: T.redLt, borderRadius: 8,
                        padding: "8px 10px", margin: "10px 0" }}>
            Could not load the offer setup: {loadError}
          </div>
        )}

        {!loading && (
          <>
            {/* Role + pay band */}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))",
                          gap: 10, marginTop: 14 }}>
              <div>
                <label style={label}>Job title on the letter</label>
                <input style={input} value={jobTitle} onChange={(e) => setJobTitle(e.target.value)}
                       placeholder="Account Representative" />
              </div>
              <div>
                <label style={label}>Reports to</label>
                <input style={input} value={reportsTo} onChange={(e) => setReportsTo(e.target.value)} />
              </div>
              <div>
                <label style={label}>Which pay band</label>
                <select style={input} value={roleKey} onChange={(e) => { setRoleKey(e.target.value); setLicenseTouched(false); }}>
                  <option value="">— pick a band —</option>
                  {roles.map(r => <option key={r.key} value={r.key}>{r.label}</option>)}
                </select>
              </div>
              {tiers.length > 1 && (
                <div>
                  <label style={label}>Step</label>
                  <select style={input} value={tierKey} onChange={(e) => { setTierKey(e.target.value); setLicenseTouched(false); }}>
                    {tiers.map(t => <option key={t.tier_key} value={t.tier_key}>{t.tier_label}</option>)}
                  </select>
                </div>
              )}
            </div>

            {payRow && (
              <div style={{ marginTop: 10, background: T.slate50, border: `1px solid ${T.slate200}`,
                            borderRadius: 10, padding: "10px 12px", boxSizing: "border-box" }}>
                <div style={{ fontSize: 12, fontWeight: 700, color: T.slate700 }}>
                  Typical pay for this step:{" "}
                  {Number(payRow.amount_min) === Number(payRow.amount_max)
                    ? `${money(payRow.amount_min, payRow.pay_period)} per ${payRow.pay_period}`
                    : `${money(payRow.amount_min, payRow.pay_period)} to ${money(payRow.amount_max, payRow.pay_period)} per ${payRow.pay_period}`}
                </div>
                {payRow.notes && (
                  <div style={{ fontSize: 11, color: T.slate500, marginTop: 4 }}>{payRow.notes}</div>
                )}
                {Array.isArray(payRow.placement_factors) && payRow.placement_factors.length > 0 && (
                  <div style={{ marginTop: 6 }}>
                    <div style={{ fontSize: 11, fontWeight: 700, color: T.slate600, marginBottom: 3 }}>
                      What moves someone up the band:
                    </div>
                    <ol style={{ margin: 0, paddingLeft: 18, fontSize: 11, color: T.slate600 }}>
                      {payRow.placement_factors.map((f, i) => (
                        <li key={i} style={{ marginBottom: 1 }}>
                          {f?.factor}{f?.preferred ? " (preferred)" : ""}
                        </li>
                      ))}
                    </ol>
                  </div>
                )}
              </div>
            )}

            {/* Pay type + amount */}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))",
                          gap: 10, marginTop: 12 }}>
              <div>
                <label style={label}>Paid how</label>
                <div style={{ display: "flex", gap: 6 }}>
                  {[["hourly", "Hourly"], ["salary", "Salary"]].map(([val, txt]) => (
                    <button
                      key={val}
                      onClick={() => setPayType(val)}
                      style={{ flex: 1, boxSizing: "border-box", padding: "8px 10px", fontSize: 12,
                               fontWeight: payType === val ? 700 : 500, cursor: "pointer", borderRadius: 8,
                               border: `1px solid ${payType === val ? T.blue : T.slate200}`,
                               background: payType === val ? T.blueLt : T.white,
                               color: payType === val ? T.blue : T.slate600 }}
                    >
                      {txt}
                    </button>
                  ))}
                </div>
              </div>
              <div>
                <label style={label}>
                  Amount {payType ? (payType === "hourly" ? "(per hour)" : "(per year)") : ""}
                </label>
                <input style={input} type="number" inputMode="decimal"
                       step={payType === "hourly" ? "0.25" : "500"}
                       value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0" />
                {payRow && payRow.pay_type === payType && (
                  <div style={{ display: "flex", gap: 6, marginTop: 6, flexWrap: "wrap" }}>
                    <button onClick={() => setAmount(String(Number(payRow.amount_min)))}
                            style={{ fontSize: 11, padding: "4px 8px", borderRadius: 6, cursor: "pointer",
                                     border: `1px solid ${T.slate200}`, background: T.white, color: T.slate600 }}>
                      Bottom {money(payRow.amount_min, payRow.pay_period)}
                    </button>
                    {Number(payRow.amount_max) !== Number(payRow.amount_min) && (
                      <button onClick={() => setAmount(String(Number(payRow.amount_max)))}
                              style={{ fontSize: 11, padding: "4px 8px", borderRadius: 6, cursor: "pointer",
                                       border: `1px solid ${T.slate200}`, background: T.white, color: T.slate600 }}>
                        Top {money(payRow.amount_max, payRow.pay_period)}
                      </button>
                    )}
                  </div>
                )}
                {outOfBand && (
                  <div style={{ fontSize: 11, color: T.amber, background: T.amberLt, borderRadius: 6,
                                padding: "5px 8px", marginTop: 6, boxSizing: "border-box" }}>
                    {outOfBand === "type"
                      ? "This band is normally paid the other way. Double-check before sending."
                      : `This is ${outOfBand} the typical band for this step.`}
                  </div>
                )}
              </div>
              <div>
                <label style={label}>Start date</label>
                <input style={input} type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} />
              </div>
              <div>
                <label style={label}>Reply by</label>
                <input style={input} type="date" value={respondBy} onChange={(e) => setRespondBy(e.target.value)} />
              </div>
            </div>

            <div style={{ marginTop: 12 }}>
              <label style={label}>Licence wording</label>
              <textarea
                style={{ ...input, minHeight: 74, resize: "vertical", fontFamily: "inherit", lineHeight: 1.5 }}
                value={licenseClause}
                onChange={(e) => { setLicenseClause(e.target.value); setLicenseTouched(true); }}
              />
            </div>

            {stillBlank.length > 0 && (
              <div style={{ fontSize: 11, color: T.amber, background: T.amberLt, borderRadius: 8,
                            padding: "7px 10px", marginTop: 10, boxSizing: "border-box" }}>
                Still to fill in: {stillBlank.join(", ")}
              </div>
            )}

            {/* Letter preview */}
            <div style={{ marginTop: 14 }}>
              <button
                onClick={() => setShowLetter(v => !v)}
                style={{ fontSize: 12, fontWeight: 700, color: T.blue, background: "none",
                         border: "none", cursor: "pointer", padding: 0 }}
              >
                {showLetter ? "Hide the letter" : "Read the letter"}
              </button>
              {showLetter && (
                <pre style={{ marginTop: 8, background: T.slate50, border: `1px solid ${T.slate200}`,
                              borderRadius: 10, padding: "12px 14px", fontSize: 12, lineHeight: 1.6,
                              color: T.slate800, whiteSpace: "pre-wrap", wordBreak: "break-word",
                              boxSizing: "border-box", maxHeight: 320, overflowY: "auto",
                              fontFamily: "inherit" }}>
                  {letter || "No letter template found. Add one to offer_letter_templates."}
                </pre>
              )}
            </div>

            {/* Actions */}
            <div style={{ display: "flex", gap: 8, marginTop: 16, flexWrap: "wrap",
                          justifyContent: "flex-end" }}>
              <button onClick={onClose}
                      style={{ padding: "9px 14px", fontSize: 13, borderRadius: 8, cursor: "pointer",
                               border: `1px solid ${T.slate200}`, background: T.white, color: T.slate600 }}>
                Cancel
              </button>
              <button onClick={copyLetter} disabled={!letter}
                      style={{ padding: "9px 14px", fontSize: 13, borderRadius: 8,
                               cursor: letter ? "pointer" : "not-allowed",
                               border: `1px solid ${T.slate200}`, background: T.white,
                               color: letter ? T.slate700 : T.slate400 }}>
                {copied ? "Copied" : "Copy letter"}
              </button>
              <button onClick={save} disabled={!canSave}
                      style={{ padding: "9px 16px", fontSize: 13, fontWeight: 700, borderRadius: 8,
                               cursor: canSave ? "pointer" : "not-allowed", border: "none",
                               background: canSave ? T.blue : T.slate200,
                               color: canSave ? T.white : T.slate500 }}>
                {saving ? "Saving…" : "Save offer & move stage"}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
