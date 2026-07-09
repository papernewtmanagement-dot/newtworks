import { useState, useEffect, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

// =====================================================================
// PFA.jsx — Premium Fund Account (team-facing)
//
// One person per day does the actual bank deposit. Throughout the day
// they enter every customer premium here (masked name + policy type +
// amount + optional check#). At end of day, they press Close Day, which:
//   - Locks pfa_record_customer_deposit for the rest of the CT day
//   - Fires a per-deposit Telegram summary to the team group so
//     everyone can cross-check against the SF-side final deposit
//
// Constraints (2026-07-09):
//   - Customer name masked: "First L." only
//   - No policy/app number, no free-text notes
//   - policy_type is one of: auto | fire | life | health | billing
// =====================================================================

const POLICY_TYPES = [
  { value: "auto",    label: "Auto" },
  { value: "fire",    label: "Fire" },
  { value: "life",    label: "Life" },
  { value: "health",  label: "Health" },
  { value: "billing", label: "Billing" },
];

const fieldLabel = {
  fontSize: 12,
  fontWeight: 600,
  color: T.slate700,
  textTransform: "uppercase",
  letterSpacing: 0.4,
  marginBottom: 6,
  display: "block",
};

const inputBase = {
  width: "100%",
  padding: "10px 12px",
  borderRadius: 8,
  border: `1px solid ${T.slate300}`,
  background: T.white,
  color: T.slate900,
  fontSize: 15,
  outline: "none",
  boxSizing: "border-box",
};

function fmtMoney(n) {
  const x = Number(n);
  if (!isFinite(x)) return "0.00";
  return x.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function fmtTime(iso) {
  try {
    return new Date(iso).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  } catch { return ""; }
}

export default function PFA() {
  const [firstName, setFirstName]     = useState("");
  const [lastInitial, setLastInitial] = useState("");
  const [policyType, setPolicyType]   = useState("");
  const [amount, setAmount]           = useState("");
  const [checkNumber, setCheckNumber] = useState("");

  const [submitting, setSubmitting]   = useState(false);
  const [error, setError]             = useState("");
  const [confirmation, setConfirmation] = useState(null);

  const [summary, setSummary]         = useState(null);
  const [summaryLoading, setSummaryLoading] = useState(true);
  const [summaryError, setSummaryError] = useState("");

  const [closing, setClosing]         = useState(false);
  const [closeError, setCloseError]   = useState("");

  const trimmedFirst = firstName.trim();
  const trimmedInitial = lastInitial.trim();
  const maskedPreview = trimmedFirst && /^[A-Za-z]$/.test(trimmedInitial)
    ? `${trimmedFirst} ${trimmedInitial.toUpperCase()}.`
    : "";

  const dayClosed = !!summary?.day_closed;
  const depositCount = summary?.deposit_count ?? 0;
  const totalAmount = Number(summary?.total_amount ?? 0);

  const canSubmit =
    !!maskedPreview &&
    !!policyType &&
    Number(amount) > 0 &&
    !submitting &&
    !dayClosed;

  const canClose = !dayClosed && depositCount > 0 && !closing;

  const loadSummary = useCallback(async () => {
    setSummaryError("");
    try {
      const { data, error } = await supabase.rpc("pfa_today_summary");
      if (error) throw error;
      setSummary(data);
    } catch (e) {
      setSummaryError(e?.message || String(e));
    } finally {
      setSummaryLoading(false);
    }
  }, []);

  useEffect(() => { loadSummary(); }, [loadSummary]);

  const resetForm = () => {
    setFirstName("");
    setLastInitial("");
    setPolicyType("");
    setAmount("");
    setCheckNumber("");
    setError("");
  };

  const handleSubmit = async () => {
    setError("");
    setConfirmation(null);

    if (!trimmedFirst) { setError("First name is required."); return; }
    if (/\./.test(trimmedFirst)) { setError("First name should not contain a period."); return; }
    if (!/^[A-Za-z]$/.test(trimmedInitial)) { setError("Last initial must be a single letter."); return; }
    if (!POLICY_TYPES.some(p => p.value === policyType)) { setError("Pick a policy type."); return; }
    const amtNum = Number(amount);
    if (!isFinite(amtNum) || amtNum <= 0) { setError("Amount must be greater than $0.00."); return; }
    if (amtNum > 100000) { setError("Amount unreasonably large — double-check before submitting."); return; }

    setSubmitting(true);
    try {
      const { data, error: rpcErr } = await supabase.rpc("pfa_record_customer_deposit", {
        p_first_name:   trimmedFirst,
        p_last_initial: trimmedInitial,
        p_policy_type:  policyType,
        p_amount:       amtNum,
        p_check_number: checkNumber.trim() || null,
      });
      if (rpcErr) { setError(rpcErr.message || "Deposit could not be recorded."); return; }
      if (!data || data.ok !== true) { setError((data && data.error) || "Deposit could not be recorded."); return; }

      setConfirmation({
        customer:   data.customer_name,
        amount:     data.amount,
        policy_type: data.policy_type,
      });
      resetForm();
      await loadSummary();
    } catch (e) {
      setError(String(e?.message || e));
    } finally {
      setSubmitting(false);
    }
  };

  const handleCloseDay = async () => {
    setCloseError("");
    const proceed = window.confirm(
      `Close the day with ${depositCount} deposit${depositCount === 1 ? "" : "s"} totaling $${fmtMoney(totalAmount)}?\n\nThis will notify the team and lock further entries for today.`
    );
    if (!proceed) return;

    setClosing(true);
    try {
      const { data, error: rpcErr } = await supabase.rpc("pfa_close_day");
      if (rpcErr) { setCloseError(rpcErr.message || "Close failed."); return; }
      if (!data || data.ok !== true) { setCloseError((data && data.error) || "Close failed."); return; }
      await loadSummary();
    } catch (e) {
      setCloseError(String(e?.message || e));
    } finally {
      setClosing(false);
    }
  };

  return (
    <div style={{
      flex: 1,
      background: T.slate50,
      padding: "24px 20px 40px",
      overflowY: "auto",
    }}>
      <div style={{ maxWidth: 560, margin: "0 auto" }}>
        {/* Header */}
        <div style={{ marginBottom: 20 }}>
          <div style={{ fontSize: 22, fontWeight: 800, color: T.slate900, lineHeight: 1.2 }}>
            Premium Fund Account
          </div>
          <div style={{ fontSize: 14, color: T.slate500, marginTop: 6, lineHeight: 1.5 }}>
            Record every customer premium payment (check, cash, transfer) taken today. Press Close Day when the deposit is done.
          </div>
        </div>

        {/* Confirmation banner (last-entered deposit) */}
        {confirmation && (
          <div style={{
            marginBottom: 16,
            padding: "12px 14px",
            borderRadius: 10,
            background: T.blueLt,
            border: `1px solid ${T.blue}`,
            color: T.slate900,
          }}>
            <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 4 }}>
              ✓ Deposit recorded
            </div>
            <div style={{ fontSize: 13, lineHeight: 1.5 }}>
              {confirmation.customer} — ${fmtMoney(confirmation.amount)} ({confirmation.policy_type})
            </div>
          </div>
        )}

        {/* Today block: list + total + Close Day button */}
        <div style={{
          background: T.white,
          borderRadius: 12,
          border: `1px solid ${T.slate200}`,
          padding: 16,
          marginBottom: 16,
          boxShadow: "0 1px 2px rgba(0,0,0,0.04)",
        }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 10 }}>
            <div style={{ fontSize: 13, fontWeight: 700, color: T.slate700, textTransform: "uppercase", letterSpacing: 0.4 }}>
              Today
            </div>
            {!summaryLoading && (
              <div style={{ fontSize: 13, color: T.slate500 }}>
                {depositCount} deposit{depositCount === 1 ? "" : "s"} · <strong style={{ color: T.slate900 }}>${fmtMoney(totalAmount)}</strong>
              </div>
            )}
          </div>

          {summaryLoading && (
            <div style={{ fontSize: 13, color: T.slate500 }}>Loading…</div>
          )}
          {summaryError && (
            <div style={{ fontSize: 13, color: "#7B241C" }}>Couldn't load today's summary: {summaryError}</div>
          )}

          {!summaryLoading && depositCount === 0 && !dayClosed && (
            <div style={{ fontSize: 13, color: T.slate500, fontStyle: "italic" }}>
              No deposits yet today.
            </div>
          )}

          {!summaryLoading && depositCount > 0 && (
            <div style={{ fontSize: 13, color: T.slate800 }}>
              {(summary?.deposits || []).map((d) => (
                <div key={d.id} style={{
                  padding: "6px 0",
                  borderBottom: `1px solid ${T.slate100}`,
                  display: "flex",
                  justifyContent: "space-between",
                  gap: 8,
                }}>
                  <span>
                    <strong>${fmtMoney(d.amount)}</strong> · {d.customer_name} · {d.policy_type}
                    {d.check_number ? ` · #${d.check_number}` : ""}
                  </span>
                  <span style={{ color: T.slate500, fontSize: 12, whiteSpace: "nowrap" }}>
                    {d.entered_by ? `${d.entered_by} · ` : ""}{fmtTime(d.entered_at)}
                  </span>
                </div>
              ))}
            </div>
          )}

          {/* Close Day state */}
          {dayClosed ? (
            <div style={{
              marginTop: 14,
              padding: "10px 12px",
              borderRadius: 8,
              background: T.blueLt,
              border: `1px solid ${T.blue}`,
              color: T.slate900,
              fontSize: 13,
              lineHeight: 1.5,
            }}>
              <div style={{ fontWeight: 700, marginBottom: 2 }}>✓ Day closed</div>
              Closed by {summary?.close?.closed_by || "team member"} at {fmtTime(summary?.close?.closed_at)}.
              {summary?.close?.telegram_send_ok === false && (
                <div style={{ marginTop: 6, color: "#7B241C" }}>
                  ⚠ Telegram notification did not send{summary?.close?.telegram_send_error ? `: ${summary.close.telegram_send_error}` : ""}. The close is recorded — let Peter know so it can be resent.
                </div>
              )}
            </div>
          ) : (
            <>
              <button
                type="button"
                onClick={handleCloseDay}
                disabled={!canClose}
                style={{
                  marginTop: 14,
                  width: "100%",
                  padding: "10px 14px",
                  borderRadius: 8,
                  border: `1px solid ${canClose ? T.blue : T.slate300}`,
                  background: canClose ? T.white : T.slate50,
                  color: canClose ? T.blue : T.slate400,
                  fontSize: 14,
                  fontWeight: 700,
                  cursor: canClose ? "pointer" : "not-allowed",
                }}
              >
                {closing ? "Closing…" : `Close day${depositCount > 0 ? ` (${depositCount})` : ""}`}
              </button>
              {closeError && (
                <div style={{ marginTop: 8, fontSize: 13, color: "#7B241C" }}>{closeError}</div>
              )}
            </>
          )}
        </div>

        {/* Entry form — hidden after Close Day */}
        {!dayClosed && (
          <div style={{
            background: T.white,
            borderRadius: 12,
            border: `1px solid ${T.slate200}`,
            padding: 20,
            boxShadow: "0 1px 2px rgba(0,0,0,0.04)",
          }}>
            <div style={{ marginBottom: 16 }}>
              <label style={fieldLabel} htmlFor="pfa-first">First name</label>
              <input
                id="pfa-first" type="text" value={firstName}
                onChange={e => setFirstName(e.target.value)}
                placeholder="Jane" autoComplete="off" maxLength={40}
                style={inputBase}
              />
            </div>

            <div style={{ marginBottom: 16 }}>
              <label style={fieldLabel} htmlFor="pfa-initial">Last initial</label>
              <input
                id="pfa-initial" type="text" value={lastInitial}
                onChange={e => {
                  const v = e.target.value.replace(/[^A-Za-z]/g, "").slice(0, 1);
                  setLastInitial(v);
                }}
                placeholder="D" autoComplete="off" maxLength={1}
                style={{ ...inputBase, width: 80, textAlign: "center", textTransform: "uppercase" }}
              />
              <div style={{ fontSize: 12, color: T.slate500, marginTop: 6 }}>
                We store the customer as <strong style={{ color: T.slate900 }}>{maskedPreview || "First L."}</strong> — full last names aren't kept in Newtworks.
              </div>
            </div>

            <div style={{ marginBottom: 16 }}>
              <label style={fieldLabel} htmlFor="pfa-policy">Policy type</label>
              <select
                id="pfa-policy" value={policyType}
                onChange={e => setPolicyType(e.target.value)}
                style={{ ...inputBase, cursor: "pointer", appearance: "auto" }}
              >
                <option value="">Select…</option>
                {POLICY_TYPES.map(p => (
                  <option key={p.value} value={p.value}>{p.label}</option>
                ))}
              </select>
            </div>

            <div style={{ marginBottom: 16 }}>
              <label style={fieldLabel} htmlFor="pfa-amount">Amount ($)</label>
              <input
                id="pfa-amount" type="number" inputMode="decimal" step="0.01" min="0"
                value={amount} onChange={e => setAmount(e.target.value)}
                placeholder="0.00" style={inputBase}
              />
            </div>

            <div style={{ marginBottom: 20 }}>
              <label style={fieldLabel} htmlFor="pfa-check">
                Check number <span style={{ textTransform: "none", fontWeight: 500, color: T.slate500 }}>(optional)</span>
              </label>
              <input
                id="pfa-check" type="text" value={checkNumber}
                onChange={e => setCheckNumber(e.target.value)}
                placeholder="e.g. 1042" autoComplete="off" maxLength={20}
                style={inputBase}
              />
            </div>

            {error && (
              <div style={{
                marginBottom: 14,
                padding: "10px 12px",
                borderRadius: 8,
                background: "#FDECEA",
                border: "1px solid #F5B7B1",
                color: "#7B241C",
                fontSize: 13,
                lineHeight: 1.4,
              }}>
                {error}
              </div>
            )}

            <button
              type="button" onClick={handleSubmit} disabled={!canSubmit}
              style={{
                width: "100%",
                padding: "12px 16px",
                borderRadius: 10,
                border: "none",
                background: canSubmit ? T.blue : T.slate300,
                color: canSubmit ? T.white : T.slate500,
                fontSize: 15,
                fontWeight: 700,
                cursor: canSubmit ? "pointer" : "not-allowed",
                transition: "background 0.15s",
              }}
            >
              {submitting ? "Recording…" : "Record deposit"}
            </button>
          </div>
        )}

        <div style={{ fontSize: 12, color: T.slate500, marginTop: 16, lineHeight: 1.5 }}>
          Deposits sync to the monthly PFA reconciliation. Ledger, statements, and reconciliations are visible to the agency owner only.
        </div>
      </div>
    </div>
  );
}
