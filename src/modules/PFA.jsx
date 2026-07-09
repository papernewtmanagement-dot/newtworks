import { useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

// =====================================================================
// PFA.jsx — Premium Fund Account deposit entry (team-facing)
//
// Team members enter customer premium deposits. Behind the scenes the
// pfa_record_customer_deposit RPC inserts paired Deposit + State Farm EFT
// rows and sends Peter a Telegram DM.
//
// Constraints (per Peter, 2026-07-09):
//   - Customer identity is masked: first name + last initial + period.
//     Full last names, policy numbers, and free-text notes are prohibited.
//   - policy_type is one of: auto | fire | life | health | billing.
//   - Check number is optional.
//
// Ledger / statement / reconciliation views are admin-only and live
// elsewhere. This module is intentionally simple: one form, one action.
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

function formatAmountForPreview(raw) {
  const n = Number(raw);
  if (!isFinite(n) || n <= 0) return "";
  return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export default function PFA() {
  const [firstName, setFirstName]     = useState("");
  const [lastInitial, setLastInitial] = useState("");
  const [policyType, setPolicyType]   = useState("");
  const [amount, setAmount]           = useState("");
  const [checkNumber, setCheckNumber] = useState("");
  const [submitting, setSubmitting]   = useState(false);
  const [error, setError]             = useState("");
  const [confirmation, setConfirmation] = useState(null); // { customer, amount, policy_type }

  const trimmedFirst = firstName.trim();
  const trimmedInitial = lastInitial.trim();
  const maskedPreview = trimmedFirst && /^[A-Za-z]$/.test(trimmedInitial)
    ? `${trimmedFirst} ${trimmedInitial.toUpperCase()}.`
    : "";

  const canSubmit =
    !!maskedPreview &&
    !!policyType &&
    Number(amount) > 0 &&
    !submitting;

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

    // Client-side guards (server enforces same rules)
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

      if (rpcErr) {
        setError(rpcErr.message || "Deposit could not be recorded.");
        return;
      }
      if (!data || data.ok !== true) {
        setError((data && data.error) || "Deposit could not be recorded.");
        return;
      }

      setConfirmation({
        customer:   data.customer_name,
        amount:     data.amount,
        policy_type: data.policy_type,
        prepared_by: data.prepared_by,
        transaction_date: data.transaction_date,
      });
      resetForm();
    } catch (e) {
      setError(String(e?.message || e));
    } finally {
      setSubmitting(false);
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
            Record a customer premium deposit. The bank slip goes to Frost;
            this entry keeps the PFA ledger in sync and pings Peter.
          </div>
        </div>

        {/* Confirmation banner */}
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
              {confirmation.customer} — ${formatAmountForPreview(confirmation.amount)} ({confirmation.policy_type})
            </div>
          </div>
        )}

        {/* Form card */}
        <div style={{
          background: T.white,
          borderRadius: 12,
          border: `1px solid ${T.slate200}`,
          padding: 20,
          boxShadow: "0 1px 2px rgba(0,0,0,0.04)",
        }}>
          {/* First name */}
          <div style={{ marginBottom: 16 }}>
            <label style={fieldLabel} htmlFor="pfa-first">First name</label>
            <input
              id="pfa-first"
              type="text"
              value={firstName}
              onChange={e => setFirstName(e.target.value)}
              placeholder="Jane"
              autoComplete="off"
              maxLength={40}
              style={inputBase}
            />
          </div>

          {/* Last initial */}
          <div style={{ marginBottom: 16 }}>
            <label style={fieldLabel} htmlFor="pfa-initial">Last initial</label>
            <input
              id="pfa-initial"
              type="text"
              value={lastInitial}
              onChange={e => {
                // Keep only the first letter typed
                const v = e.target.value.replace(/[^A-Za-z]/g, "").slice(0, 1);
                setLastInitial(v);
              }}
              placeholder="D"
              autoComplete="off"
              maxLength={1}
              style={{ ...inputBase, width: 80, textAlign: "center", textTransform: "uppercase" }}
            />
            <div style={{ fontSize: 12, color: T.slate500, marginTop: 6 }}>
              We store the customer as <strong style={{ color: T.slate900 }}>{maskedPreview || "First L."}</strong> — full last names aren't kept in Newtworks.
            </div>
          </div>

          {/* Policy type */}
          <div style={{ marginBottom: 16 }}>
            <label style={fieldLabel} htmlFor="pfa-policy">Policy type</label>
            <select
              id="pfa-policy"
              value={policyType}
              onChange={e => setPolicyType(e.target.value)}
              style={{ ...inputBase, cursor: "pointer", appearance: "auto" }}
            >
              <option value="">Select…</option>
              {POLICY_TYPES.map(p => (
                <option key={p.value} value={p.value}>{p.label}</option>
              ))}
            </select>
          </div>

          {/* Amount */}
          <div style={{ marginBottom: 16 }}>
            <label style={fieldLabel} htmlFor="pfa-amount">Amount ($)</label>
            <input
              id="pfa-amount"
              type="number"
              inputMode="decimal"
              step="0.01"
              min="0"
              value={amount}
              onChange={e => setAmount(e.target.value)}
              placeholder="0.00"
              style={inputBase}
            />
          </div>

          {/* Check number (optional) */}
          <div style={{ marginBottom: 20 }}>
            <label style={fieldLabel} htmlFor="pfa-check">
              Check number <span style={{ textTransform: "none", fontWeight: 500, color: T.slate500 }}>(optional)</span>
            </label>
            <input
              id="pfa-check"
              type="text"
              value={checkNumber}
              onChange={e => setCheckNumber(e.target.value)}
              placeholder="e.g. 1042"
              autoComplete="off"
              maxLength={20}
              style={inputBase}
            />
          </div>

          {/* Error */}
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

          {/* Submit */}
          <button
            type="button"
            onClick={handleSubmit}
            disabled={!canSubmit}
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

        {/* Footnote */}
        <div style={{ fontSize: 12, color: T.slate500, marginTop: 16, lineHeight: 1.5 }}>
          Deposits sync to the monthly PFA reconciliation. Ledger, statements, and reconciliations are visible to the agency owner only.
        </div>
      </div>
    </div>
  );
}
