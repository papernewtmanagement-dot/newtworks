import React, { useState, useEffect, useCallback, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

// =====================================================================
// PFA.jsx — Premium Fund Account
//
// Team view (staff): entry form + Today panel + Close Day button.
// Admin view (owner/manager): tabbed layout —
//   • Today          — same live view team sees
//   • Ledger         — full pfa_transactions history, filters, void action
//   • Statements     — pfa_bank_statements list
//   • Reconciliations — pfa_reconciliations list
//   • Closes         — pfa_daily_closes list, resend Telegram if failed
// =====================================================================

const POLICY_TYPES = [
  { value: "auto",    label: "Auto" },
  { value: "fire",    label: "Fire" },
  { value: "life",    label: "Life" },
  { value: "health",  label: "Health" },
  { value: "billing", label: "Billing" },
];

// ------ shared styles ------------------------------------------------
const fieldLabel = {
  fontSize: 12, fontWeight: 600, color: T.slate700,
  textTransform: "uppercase", letterSpacing: 0.4,
  marginBottom: 6, display: "block",
};
const inputBase = {
  width: "100%", padding: "10px 12px", borderRadius: 8,
  border: `1px solid ${T.slate300}`, background: T.white, color: T.slate900,
  fontSize: 15, outline: "none", boxSizing: "border-box",
};
const cardStyle = {
  background: T.white, borderRadius: 12,
  border: `1px solid ${T.slate200}`, padding: 20,
  boxShadow: "0 1px 2px rgba(0,0,0,0.04)",
};
const tableTh = {
  fontSize: 11, fontWeight: 700, color: T.slate500,
  textTransform: "uppercase", letterSpacing: 0.4,
  padding: "8px 6px", borderBottom: `1px solid ${T.slate200}`,
  textAlign: "left", whiteSpace: "nowrap",
};
const tableTd = {
  fontSize: 13, color: T.slate800,
  padding: "8px 6px", borderBottom: `1px solid ${T.slate100}`,
  verticalAlign: "top",
};

// ------ helpers ------------------------------------------------------
function fmtMoney(n) {
  const x = Number(n);
  if (!isFinite(x)) return "0.00";
  return x.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
function fmtTime(iso) {
  try { return new Date(iso).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" }); }
  catch { return ""; }
}
function fmtDate(iso) {
  if (!iso) return "";
  // Handle bare YYYY-MM-DD without shifting for the local tz
  if (/^\d{4}-\d{2}-\d{2}$/.test(iso)) {
    const [y, m, d] = iso.split("-").map(Number);
    return new Date(y, m - 1, d).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
  }
  try { return new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }); }
  catch { return iso; }
}
function toIsoDate(d) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${dd}`;
}
function daysAgo(n) {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return toIsoDate(d);
}
function firstOfPriorMonth() {
  const d = new Date();
  d.setDate(1);
  d.setMonth(d.getMonth() - 1);
  return toIsoDate(d);
}

// =====================================================================
// TeamEntryAndToday — the team-facing view (entry form + Today panel).
// Rendered under the Today tab for admins too.
// =====================================================================
function TeamEntryAndToday() {
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
    !!maskedPreview && !!policyType &&
    Number(amount) > 0 && !submitting && !dayClosed;
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
    setFirstName(""); setLastInitial(""); setPolicyType("");
    setAmount(""); setCheckNumber(""); setError("");
  };

  const handleSubmit = async () => {
    setError(""); setConfirmation(null);
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
        p_first_name: trimmedFirst, p_last_initial: trimmedInitial,
        p_policy_type: policyType, p_amount: amtNum,
        p_check_number: checkNumber.trim() || null,
      });
      if (rpcErr) { setError(rpcErr.message || "Deposit could not be recorded."); return; }
      if (!data || data.ok !== true) { setError((data && data.error) || "Deposit could not be recorded."); return; }
      setConfirmation({ customer: data.customer_name, amount: data.amount, policy_type: data.policy_type });
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
    <div>
      {confirmation && (
        <div style={{
          marginBottom: 16, padding: "12px 14px", borderRadius: 10,
          background: T.blueLt, border: `1px solid ${T.blue}`, color: T.slate900,
        }}>
          <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 4 }}>✓ Deposit recorded</div>
          <div style={{ fontSize: 13, lineHeight: 1.5 }}>
            {confirmation.customer} — ${fmtMoney(confirmation.amount)} ({confirmation.policy_type})
          </div>
        </div>
      )}

      {/* Today block */}
      <div style={{ ...cardStyle, padding: 16, marginBottom: 16 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 10 }}>
          <div style={{ fontSize: 13, fontWeight: 700, color: T.slate700, textTransform: "uppercase", letterSpacing: 0.4 }}>Today</div>
          {!summaryLoading && (
            <div style={{ fontSize: 13, color: T.slate500 }}>
              {depositCount} deposit{depositCount === 1 ? "" : "s"} · <strong style={{ color: T.slate900 }}>${fmtMoney(totalAmount)}</strong>
            </div>
          )}
        </div>

        {summaryLoading && <div style={{ fontSize: 13, color: T.slate500 }}>Loading…</div>}
        {summaryError && <div style={{ fontSize: 13, color: "#7B241C" }}>Couldn't load today's summary: {summaryError}</div>}

        {!summaryLoading && depositCount === 0 && !dayClosed && (
          <div style={{ fontSize: 13, color: T.slate500, fontStyle: "italic" }}>No deposits yet today.</div>
        )}

        {!summaryLoading && depositCount > 0 && (
          <div style={{ fontSize: 13, color: T.slate800 }}>
            {(summary?.deposits || []).map((d) => (
              <div key={d.id} style={{
                padding: "6px 0", borderBottom: `1px solid ${T.slate100}`,
                display: "flex", justifyContent: "space-between", gap: 8,
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

        {dayClosed ? (
          <div style={{
            marginTop: 14, padding: "10px 12px", borderRadius: 8,
            background: T.blueLt, border: `1px solid ${T.blue}`, color: T.slate900,
            fontSize: 13, lineHeight: 1.5,
          }}>
            <div style={{ fontWeight: 700, marginBottom: 2 }}>✓ Day closed</div>
            Closed by {summary?.close?.closed_by || "team member"} at {fmtTime(summary?.close?.closed_at)}.
            {summary?.close?.telegram_send_ok === false && (
              <div style={{ marginTop: 6, color: "#7B241C" }}>
                ⚠ Telegram notification did not send{summary?.close?.telegram_send_error ? `: ${summary.close.telegram_send_error}` : ""}.
              </div>
            )}
          </div>
        ) : (
          <>
            <button type="button" onClick={handleCloseDay} disabled={!canClose}
              style={{
                marginTop: 14, width: "100%", padding: "10px 14px", borderRadius: 8,
                border: `1px solid ${canClose ? T.blue : T.slate300}`,
                background: canClose ? T.white : T.slate50,
                color: canClose ? T.blue : T.slate400,
                fontSize: 14, fontWeight: 700,
                cursor: canClose ? "pointer" : "not-allowed",
              }}>
              {closing ? "Closing…" : `Close day${depositCount > 0 ? ` (${depositCount})` : ""}`}
            </button>
            {closeError && <div style={{ marginTop: 8, fontSize: 13, color: "#7B241C" }}>{closeError}</div>}
          </>
        )}
      </div>

      {/* Entry form */}
      {!dayClosed && (
        <div style={cardStyle}>
          <div style={{ marginBottom: 16 }}>
            <label style={fieldLabel} htmlFor="pfa-first">First name</label>
            <input id="pfa-first" type="text" value={firstName}
              onChange={e => setFirstName(e.target.value)}
              placeholder="Jane" autoComplete="off" maxLength={40} style={inputBase} />
          </div>
          <div style={{ marginBottom: 16 }}>
            <label style={fieldLabel} htmlFor="pfa-initial">Last initial</label>
            <input id="pfa-initial" type="text" value={lastInitial}
              onChange={e => {
                const v = e.target.value.replace(/[^A-Za-z]/g, "").slice(0, 1);
                setLastInitial(v);
              }}
              placeholder="D" autoComplete="off" maxLength={1}
              style={{ ...inputBase, width: 80, textAlign: "center", textTransform: "uppercase" }} />
            <div style={{ fontSize: 12, color: T.slate500, marginTop: 6 }}>
              We store the customer as <strong style={{ color: T.slate900 }}>{maskedPreview || "First L."}</strong> — full last names aren't kept in Newtworks.
            </div>
          </div>
          <div style={{ marginBottom: 16 }}>
            <label style={fieldLabel} htmlFor="pfa-policy">Policy type</label>
            <select id="pfa-policy" value={policyType}
              onChange={e => setPolicyType(e.target.value)}
              style={{ ...inputBase, cursor: "pointer", appearance: "auto" }}>
              <option value="">Select…</option>
              {POLICY_TYPES.map(p => <option key={p.value} value={p.value}>{p.label}</option>)}
            </select>
          </div>
          <div style={{ marginBottom: 16 }}>
            <label style={fieldLabel} htmlFor="pfa-amount">Amount ($)</label>
            <input id="pfa-amount" type="number" inputMode="decimal" step="0.01" min="0"
              value={amount} onChange={e => setAmount(e.target.value)}
              placeholder="0.00" style={inputBase} />
          </div>
          <div style={{ marginBottom: 20 }}>
            <label style={fieldLabel} htmlFor="pfa-check">
              Check number <span style={{ textTransform: "none", fontWeight: 500, color: T.slate500 }}>(optional)</span>
            </label>
            <input id="pfa-check" type="text" value={checkNumber}
              onChange={e => setCheckNumber(e.target.value)}
              placeholder="e.g. 1042" autoComplete="off" maxLength={20} style={inputBase} />
          </div>
          {error && (
            <div style={{
              marginBottom: 14, padding: "10px 12px", borderRadius: 8,
              background: "#FDECEA", border: "1px solid #F5B7B1",
              color: "#7B241C", fontSize: 13, lineHeight: 1.4,
            }}>{error}</div>
          )}
          <button type="button" onClick={handleSubmit} disabled={!canSubmit}
            style={{
              width: "100%", padding: "12px 16px", borderRadius: 10, border: "none",
              background: canSubmit ? T.blue : T.slate300,
              color: canSubmit ? T.white : T.slate500,
              fontSize: 15, fontWeight: 700,
              cursor: canSubmit ? "pointer" : "not-allowed",
              transition: "background 0.15s",
            }}>
            {submitting ? "Recording…" : "Record deposit"}
          </button>
        </div>
      )}
    </div>
  );
}

// =====================================================================
// LedgerTab — full pfa_transactions with filters + void action
// =====================================================================
function LedgerTab({ pfaAccountId, teamRoster, onReloadAccount }) {
  const [dateFrom, setDateFrom] = useState(firstOfPriorMonth());
  const [dateTo, setDateTo]     = useState(toIsoDate(new Date()));
  const [teamFilter, setTeamFilter] = useState("");   // "" | team_id | "excel"
  const [typeFilter, setTypeFilter] = useState("");   // "" | Deposit | State Farm EFT | ...
  const [clearedFilter, setClearedFilter] = useState(""); // "" | "cleared" | "uncleared"
  const [showVoided, setShowVoided] = useState(false);
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [voidingId, setVoidingId] = useState(null);
  const [voidError, setVoidError] = useState("");

  const load = useCallback(async () => {
    if (!pfaAccountId) return;
    setLoading(true);
    setError("");
    try {
      let q = supabase
        .from("pfa_transactions")
        .select(`
          id, transaction_date, transaction_type, customer_name, policy_type,
          debit_amount, credit_amount, transaction_number, cleared, cleared_date,
          imported_from_excel, prepared_by_team_member_id,
          voided_at, void_reason, notes, created_at
        `)
        .eq("pfa_account_id", pfaAccountId)
        .gte("transaction_date", dateFrom)
        .lte("transaction_date", dateTo)
        .order("transaction_date", { ascending: false })
        .order("created_at", { ascending: false })
        .limit(500);

      if (typeFilter) q = q.eq("transaction_type", typeFilter);
      if (clearedFilter === "cleared") q = q.eq("cleared", true);
      if (clearedFilter === "uncleared") q = q.eq("cleared", false);
      if (teamFilter === "excel") q = q.eq("imported_from_excel", true);
      else if (teamFilter) q = q.eq("prepared_by_team_member_id", teamFilter);
      if (!showVoided) q = q.is("voided_at", null);

      const { data, error } = await q;
      if (error) throw error;
      setRows(data || []);
    } catch (e) {
      setError(e?.message || String(e));
    } finally {
      setLoading(false);
    }
  }, [pfaAccountId, dateFrom, dateTo, typeFilter, clearedFilter, teamFilter, showVoided]);

  useEffect(() => { load(); }, [load]);

  const teamById = useMemo(() => {
    const m = new Map();
    for (const t of teamRoster || []) m.set(t.id, t);
    return m;
  }, [teamRoster]);

  const handleVoid = async (row) => {
    setVoidError("");
    const reason = window.prompt(
      `Void this deposit?\n\n${row.customer_name} — $${fmtMoney(row.credit_amount)} (${row.policy_type})\n\nReason (required, min 3 chars):`
    );
    if (!reason || reason.trim().length < 3) return;
    setVoidingId(row.id);
    try {
      const { data, error: rpcErr } = await supabase.rpc("pfa_void_deposit", {
        p_deposit_id: row.id, p_reason: reason.trim(),
      });
      if (rpcErr) { setVoidError(rpcErr.message || "Void failed."); return; }
      if (!data || data.ok !== true) { setVoidError((data && data.error) || "Void failed."); return; }
      await load();
    } catch (e) {
      setVoidError(String(e?.message || e));
    } finally {
      setVoidingId(null);
    }
  };

  const filterBoxStyle = { ...inputBase, padding: "6px 8px", fontSize: 13 };

  return (
    <div>
      <div style={{ ...cardStyle, padding: 12, marginBottom: 12 }}>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 8 }}>
          <div>
            <label style={{ ...fieldLabel, fontSize: 10, marginBottom: 3 }}>From</label>
            <input type="date" value={dateFrom} onChange={e => setDateFrom(e.target.value)} style={filterBoxStyle} />
          </div>
          <div>
            <label style={{ ...fieldLabel, fontSize: 10, marginBottom: 3 }}>To</label>
            <input type="date" value={dateTo} onChange={e => setDateTo(e.target.value)} style={filterBoxStyle} />
          </div>
          <div>
            <label style={{ ...fieldLabel, fontSize: 10, marginBottom: 3 }}>Type</label>
            <select value={typeFilter} onChange={e => setTypeFilter(e.target.value)} style={filterBoxStyle}>
              <option value="">All types</option>
              <option value="Deposit">Deposit</option>
              <option value="State Farm EFT">State Farm EFT</option>
              <option value="Bank Service Fee">Bank Service Fee</option>
              <option value="Misc Withdrawal">Misc Withdrawal</option>
              <option value="NSF/Overdraft Fee">NSF/Overdraft Fee</option>
            </select>
          </div>
          <div>
            <label style={{ ...fieldLabel, fontSize: 10, marginBottom: 3 }}>Cleared</label>
            <select value={clearedFilter} onChange={e => setClearedFilter(e.target.value)} style={filterBoxStyle}>
              <option value="">All</option>
              <option value="cleared">Cleared</option>
              <option value="uncleared">Uncleared</option>
            </select>
          </div>
          <div>
            <label style={{ ...fieldLabel, fontSize: 10, marginBottom: 3 }}>Entered by</label>
            <select value={teamFilter} onChange={e => setTeamFilter(e.target.value)} style={filterBoxStyle}>
              <option value="">Anyone</option>
              <option value="excel">Historical (Excel)</option>
              {(teamRoster || []).map(t => (
                <option key={t.id} value={t.id}>{t.first_name}</option>
              ))}
            </select>
          </div>
          <div style={{ display: "flex", alignItems: "flex-end" }}>
            <label style={{ fontSize: 12, color: T.slate700, cursor: "pointer" }}>
              <input type="checkbox" checked={showVoided} onChange={e => setShowVoided(e.target.checked)} style={{ marginRight: 6 }} />
              Show voided
            </label>
          </div>
        </div>
      </div>

      {voidError && (
        <div style={{ marginBottom: 12, padding: "10px 12px", borderRadius: 8, background: "#FDECEA", border: "1px solid #F5B7B1", color: "#7B241C", fontSize: 13 }}>
          {voidError}
        </div>
      )}

      <div style={{ ...cardStyle, padding: 0, overflowX: "auto" }}>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
          <thead>
            <tr>
              <th style={tableTh}>Date</th>
              <th style={tableTh}>Type</th>
              <th style={tableTh}>Customer</th>
              <th style={tableTh}>Policy</th>
              <th style={{ ...tableTh, textAlign: "right" }}>Debit</th>
              <th style={{ ...tableTh, textAlign: "right" }}>Credit</th>
              <th style={tableTh}>Check#</th>
              <th style={tableTh}>Cleared</th>
              <th style={tableTh}>Entered by</th>
              <th style={tableTh}></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr><td colSpan={10} style={{ ...tableTd, textAlign: "center", color: T.slate500 }}>Loading…</td></tr>
            )}
            {!loading && error && (
              <tr><td colSpan={10} style={{ ...tableTd, color: "#7B241C" }}>{error}</td></tr>
            )}
            {!loading && !error && rows.length === 0 && (
              <tr><td colSpan={10} style={{ ...tableTd, textAlign: "center", color: T.slate500, fontStyle: "italic" }}>No transactions in this range.</td></tr>
            )}
            {!loading && rows.map(r => {
              const isVoided = !!r.voided_at;
              const enteredBy = r.imported_from_excel
                ? "—"
                : (teamById.get(r.prepared_by_team_member_id)?.first_name || "—");
              const canVoid = !isVoided && !r.cleared && r.transaction_type === "Deposit" && !r.imported_from_excel;
              return (
                <tr key={r.id} style={{ opacity: isVoided ? 0.5 : 1, textDecoration: isVoided ? "line-through" : "none" }}>
                  <td style={tableTd}>{fmtDate(r.transaction_date)}</td>
                  <td style={tableTd}>{r.transaction_type}</td>
                  <td style={tableTd}>{r.customer_name || "—"}</td>
                  <td style={tableTd}>{r.policy_type ? r.policy_type : "—"}</td>
                  <td style={{ ...tableTd, textAlign: "right" }}>{r.debit_amount ? `$${fmtMoney(r.debit_amount)}` : ""}</td>
                  <td style={{ ...tableTd, textAlign: "right" }}>{r.credit_amount ? `$${fmtMoney(r.credit_amount)}` : ""}</td>
                  <td style={tableTd}>{r.transaction_number || ""}</td>
                  <td style={tableTd}>{r.cleared ? `✓ ${fmtDate(r.cleared_date)}` : ""}</td>
                  <td style={tableTd}>{enteredBy}</td>
                  <td style={tableTd}>
                    {canVoid ? (
                      <button type="button" onClick={() => handleVoid(r)} disabled={voidingId === r.id}
                        style={{
                          padding: "4px 10px", borderRadius: 6, border: `1px solid ${T.slate300}`,
                          background: T.white, color: T.slate700, fontSize: 12, cursor: "pointer",
                        }}>
                        {voidingId === r.id ? "…" : "Void"}
                      </button>
                    ) : isVoided ? (
                      <span title={r.void_reason || ""} style={{ fontSize: 11, color: T.slate500 }}>voided</span>
                    ) : null}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div style={{ fontSize: 11, color: T.slate500, marginTop: 8 }}>
        Showing up to 500 rows. Narrow the date range to see older activity.
      </div>
    </div>
  );
}

// =====================================================================
// StatementsTab — expand to see the cleared items on each statement
// =====================================================================
function StatementsTab({ pfaAccountId }) {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [expandedId, setExpandedId] = useState(null);
  const [detailsById, setDetailsById] = useState({});

  useEffect(() => {
    if (!pfaAccountId) return;
    setLoading(true); setError("");
    supabase.from("pfa_bank_statements")
      .select("id, statement_period_start, statement_period_end, opening_balance, closing_balance, deposit_total, withdrawal_total, deposit_count, withdrawal_count, created_at")
      .eq("pfa_account_id", pfaAccountId)
      .order("statement_period_end", { ascending: false })
      .then(({ data, error }) => {
        if (error) setError(error.message);
        else setRows(data || []);
        setLoading(false);
      });
  }, [pfaAccountId]);

  const toggleExpand = async (row) => {
    if (expandedId === row.id) { setExpandedId(null); return; }
    setExpandedId(row.id);
    if (detailsById[row.id]) return;
    setDetailsById(prev => ({ ...prev, [row.id]: { loading: true } }));
    const { data, error } = await supabase
      .from("pfa_transactions")
      .select("id, transaction_date, transaction_type, customer_name, policy_type, debit_amount, credit_amount, transaction_number, cleared_date")
      .eq("pfa_account_id", pfaAccountId)
      .eq("cleared", true)
      .gte("cleared_date", row.statement_period_start)
      .lte("cleared_date", row.statement_period_end)
      .is("voided_at", null)
      .order("transaction_date", { ascending: true })
      .order("created_at", { ascending: true });
    setDetailsById(prev => ({ ...prev, [row.id]: { loading: false, rows: data || [], error: error?.message } }));
  };

  return (
    <div style={{ ...cardStyle, padding: 0, overflowX: "auto" }}>
      <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
        <thead>
          <tr>
            <th style={{ ...tableTh, width: 24 }}></th>
            <th style={tableTh}>Period</th>
            <th style={{ ...tableTh, textAlign: "right" }}>Opening</th>
            <th style={{ ...tableTh, textAlign: "right" }}>Deposits</th>
            <th style={{ ...tableTh, textAlign: "right" }}>Withdrawals</th>
            <th style={{ ...tableTh, textAlign: "right" }}>Closing</th>
            <th style={tableTh}>Ingested</th>
          </tr>
        </thead>
        <tbody>
          {loading && <tr><td colSpan={7} style={{ ...tableTd, textAlign: "center", color: T.slate500 }}>Loading…</td></tr>}
          {!loading && error && <tr><td colSpan={7} style={{ ...tableTd, color: "#7B241C" }}>{error}</td></tr>}
          {!loading && !error && rows.length === 0 && (
            <tr><td colSpan={7} style={{ ...tableTd, textAlign: "center", color: T.slate500, fontStyle: "italic" }}>No statements yet.</td></tr>
          )}
          {!loading && rows.map(r => {
            const isOpen = expandedId === r.id;
            const details = detailsById[r.id];
            return (
              <React.Fragment key={r.id}>
                <tr onClick={() => toggleExpand(r)} style={{ cursor: "pointer" }}>
                  <td style={{ ...tableTd, textAlign: "center", color: T.slate500 }}>{isOpen ? "▾" : "▸"}</td>
                  <td style={tableTd}>{fmtDate(r.statement_period_start)} — {fmtDate(r.statement_period_end)}</td>
                  <td style={{ ...tableTd, textAlign: "right" }}>${fmtMoney(r.opening_balance)}</td>
                  <td style={{ ...tableTd, textAlign: "right" }}>${fmtMoney(r.deposit_total)} <span style={{ color: T.slate500, fontSize: 11 }}>({r.deposit_count})</span></td>
                  <td style={{ ...tableTd, textAlign: "right" }}>${fmtMoney(r.withdrawal_total)} <span style={{ color: T.slate500, fontSize: 11 }}>({r.withdrawal_count})</span></td>
                  <td style={{ ...tableTd, textAlign: "right", fontWeight: 700 }}>${fmtMoney(r.closing_balance)}</td>
                  <td style={tableTd}>{fmtDate(r.created_at)}</td>
                </tr>
                {isOpen && (
                  <tr>
                    <td colSpan={7} style={{ padding: "12px 20px 18px", background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
                      {details?.loading && <div style={{ fontSize: 13, color: T.slate500 }}>Loading cleared items…</div>}
                      {details?.error && <div style={{ fontSize: 13, color: "#7B241C" }}>{details.error}</div>}
                      {details && !details.loading && !details.error && (details.rows || []).length === 0 && (
                        <div style={{ fontSize: 13, color: T.slate500, fontStyle: "italic" }}>No cleared items linked to this period.</div>
                      )}
                      {details && !details.loading && (details.rows || []).length > 0 && (
                        <div>
                          <div style={{ fontSize: 12, fontWeight: 700, color: T.slate700, textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 6 }}>
                            Cleared items ({details.rows.length})
                          </div>
                          <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12, background: T.white, borderRadius: 8, overflow: "hidden", border: `1px solid ${T.slate200}` }}>
                            <thead>
                              <tr>
                                <th style={{ ...tableTh, fontSize: 10 }}>Date</th>
                                <th style={{ ...tableTh, fontSize: 10 }}>Type</th>
                                <th style={{ ...tableTh, fontSize: 10 }}>Customer</th>
                                <th style={{ ...tableTh, fontSize: 10 }}>Policy</th>
                                <th style={{ ...tableTh, fontSize: 10, textAlign: "right" }}>Debit</th>
                                <th style={{ ...tableTh, fontSize: 10, textAlign: "right" }}>Credit</th>
                                <th style={{ ...tableTh, fontSize: 10 }}>Check#</th>
                                <th style={{ ...tableTh, fontSize: 10 }}>Cleared</th>
                              </tr>
                            </thead>
                            <tbody>
                              {details.rows.map(t => (
                                <tr key={t.id}>
                                  <td style={{ ...tableTd, fontSize: 12 }}>{fmtDate(t.transaction_date)}</td>
                                  <td style={{ ...tableTd, fontSize: 12 }}>{t.transaction_type}</td>
                                  <td style={{ ...tableTd, fontSize: 12 }}>{t.customer_name || "—"}</td>
                                  <td style={{ ...tableTd, fontSize: 12 }}>{t.policy_type || "—"}</td>
                                  <td style={{ ...tableTd, fontSize: 12, textAlign: "right" }}>{t.debit_amount ? `$${fmtMoney(t.debit_amount)}` : ""}</td>
                                  <td style={{ ...tableTd, fontSize: 12, textAlign: "right" }}>{t.credit_amount ? `$${fmtMoney(t.credit_amount)}` : ""}</td>
                                  <td style={{ ...tableTd, fontSize: 12 }}>{t.transaction_number || ""}</td>
                                  <td style={{ ...tableTd, fontSize: 12 }}>{fmtDate(t.cleared_date)}</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        </div>
                      )}
                    </td>
                  </tr>
                )}
              </React.Fragment>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

// =====================================================================
// ReconciliationsTab — expand to see the waterfall + outstanding items
// =====================================================================
function ReconciliationsTab({ pfaAccountId }) {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [expandedId, setExpandedId] = useState(null);
  const [detailsById, setDetailsById] = useState({});
  const [recomputingId, setRecomputingId] = useState(null);
  const [recomputeMsg, setRecomputeMsg] = useState("");
  const [sendingId, setSendingId] = useState(null);

  const loadRows = useCallback(() => {
    if (!pfaAccountId) return;
    setLoading(true); setError("");
    return supabase.from("pfa_reconciliations")
      .select(`id, statement_id, statement_ending_date, statement_ending_balance,
               outstanding_checks_total, outstanding_sf_eft_total, outstanding_deposits_total,
               returned_checks_unreimbursed, adjusted_statement_balance,
               prior_personal_funds, current_bank_service_fees, difference_to_reconcile,
               explanation, actions_taken, reconciled_at,
               emailed_to_agent_at, emailed_to_agent_message_id, created_at`)
      .eq("pfa_account_id", pfaAccountId)
      .order("statement_ending_date", { ascending: false })
      .then(({ data, error }) => {
        if (error) setError(error.message);
        else setRows(data || []);
        setLoading(false);
      });
  }, [pfaAccountId]);

  useEffect(() => { loadRows(); }, [loadRows]);

  const toggleExpand = async (row) => {
    if (expandedId === row.id) { setExpandedId(null); return; }
    setExpandedId(row.id);
    if (detailsById[row.id]) return;
    setDetailsById(prev => ({ ...prev, [row.id]: { loading: true } }));
    const { data, error } = await supabase
      .from("pfa_transactions")
      .select("id, transaction_date, transaction_type, customer_name, policy_type, debit_amount, credit_amount, transaction_number, cleared, cleared_date")
      .eq("pfa_account_id", pfaAccountId)
      .lte("transaction_date", row.statement_ending_date)
      .is("voided_at", null)
      .order("transaction_date", { ascending: true });
    let outstanding = [];
    if (data && !error) {
      outstanding = data.filter(t =>
        t.cleared === false ||
        (t.cleared_date && t.cleared_date > row.statement_ending_date)
      );
    }
    setDetailsById(prev => ({ ...prev, [row.id]: { loading: false, rows: outstanding, error: error?.message } }));
  };

  const handleRecompute = async (reconId) => {
    setRecomputeMsg("");
    setRecomputingId(reconId);
    try {
      const { data, error: rpcErr } = await supabase.rpc("pfa_recompute_reconciliation", { p_reconciliation_id: reconId });
      if (rpcErr) { setRecomputeMsg(rpcErr.message || "Recompute failed."); return; }
      if (!data?.ok) { setRecomputeMsg((data && data.error) || "Recompute failed."); return; }
      const diff = Number(data?.difference_to_reconcile ?? 0);
      const clean = Math.abs(diff) < 0.005;
      setRecomputeMsg(`Recomputed. Difference: $${diff.toFixed(2)}${clean ? " — clean" : " — has discrepancy"}.`);
      await loadRows();
      // Force detail re-fetch on next expand
      setDetailsById(prev => { const c = { ...prev }; delete c[reconId]; return c; });
    } catch (e) {
      setRecomputeMsg(String(e?.message || e));
    } finally {
      setRecomputingId(null);
    }
  };

  const handleSend = async (recon) => {
    setRecomputeMsg("");
    const diff = Number(recon.difference_to_reconcile ?? 0);
    const isClean = Math.abs(diff) < 0.005;
    const monthLabel = fmtDate(recon.statement_ending_date);
    let force = false;
    let proceed;
    if (isClean) {
      proceed = window.confirm(
        `Send the ${monthLabel} PFA reconciliation to State Farm?\n\n` +
        `Recipient: peter.story.yrru@statefarm.com\n` +
        `Difference: $0.00 (clean)\n\n` +
        `This generates the PDF and emails it.`
      );
    } else {
      force = true;
      proceed = window.confirm(
        `⚠️ This reconciliation has a DISCREPANCY of $${fmtMoney(Math.abs(diff))}.\n\n` +
        `Sending anyway will still email SF. Are you sure you've reviewed and want to send?\n\n` +
        `Type OK only if the discrepancy has an explanation SF will accept.`
      );
    }
    if (!proceed) return;
    setSendingId(recon.id);
    try {
      const { data, error: rpcErr } = await supabase.rpc("pfa_send_reconciliation", {
        p_reconciliation_id: recon.id, p_force: force,
      });
      if (rpcErr) { setRecomputeMsg(rpcErr.message || "Send failed."); return; }
      const status = data?.status || "unknown";
      const okSent = data?.ok === true && status === "sent";
      if (okSent) {
        setRecomputeMsg(`Sent to SF. Message ID: ${data?.message_id || "unknown"}.`);
      } else if (status === "already_sent") {
        setRecomputeMsg(`Already sent (${fmtDate(data?.emailed_at)}).`);
      } else if (status === "skipped_discrepancy") {
        setRecomputeMsg(`Skipped: reconciliation has a discrepancy of $${fmtMoney(Math.abs(data?.difference ?? 0))}. Recompute or override with force.`);
      } else {
        setRecomputeMsg(`Send did not complete: ${data?.error || status}`);
      }
      await loadRows();
    } catch (e) {
      setRecomputeMsg(String(e?.message || e));
    } finally {
      setSendingId(null);
    }
  };

  const waterfallRow = (label, amount, opts = {}) => (
    <div style={{
      display: "flex", justifyContent: "space-between", padding: "6px 0",
      borderBottom: opts.emphasize ? `1px solid ${T.slate300}` : `1px solid ${T.slate100}`,
      fontSize: 13, fontWeight: opts.emphasize ? 700 : 400,
      color: opts.negative ? "#7B241C" : T.slate800,
    }}>
      <span>{label}</span>
      <span style={{ fontVariantNumeric: "tabular-nums" }}>
        {opts.sign === "minus" ? "− " : opts.sign === "plus" ? "+ " : ""}${fmtMoney(amount ?? 0)}
      </span>
    </div>
  );

  return (
    <div>
      {recomputeMsg && (
        <div style={{ marginBottom: 12, padding: "10px 12px", borderRadius: 8, background: T.slate50, border: `1px solid ${T.slate200}`, fontSize: 13, color: T.slate800 }}>
          {recomputeMsg}
        </div>
      )}
      <div style={{ ...cardStyle, padding: 0, overflowX: "auto" }}>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
          <thead>
            <tr>
              <th style={{ ...tableTh, width: 24 }}></th>
              <th style={tableTh}>Statement ending</th>
              <th style={{ ...tableTh, textAlign: "right" }}>Adj. balance</th>
              <th style={{ ...tableTh, textAlign: "right" }}>Personal funds</th>
              <th style={{ ...tableTh, textAlign: "right" }}>Difference</th>
              <th style={tableTh}>Sent to SF</th>
              <th style={tableTh}></th>
            </tr>
          </thead>
          <tbody>
            {loading && <tr><td colSpan={7} style={{ ...tableTd, textAlign: "center", color: T.slate500 }}>Loading…</td></tr>}
            {!loading && error && <tr><td colSpan={7} style={{ ...tableTd, color: "#7B241C" }}>{error}</td></tr>}
            {!loading && !error && rows.length === 0 && (
              <tr><td colSpan={7} style={{ ...tableTd, textAlign: "center", color: T.slate500, fontStyle: "italic" }}>No reconciliations yet.</td></tr>
            )}
            {!loading && rows.map(r => {
              const diff = Number(r.difference_to_reconcile ?? 0);
              const isClean = Math.abs(diff) < 0.005;
              const isOpen = expandedId === r.id;
              const details = detailsById[r.id];
              return (
                <React.Fragment key={r.id}>
                  <tr onClick={() => toggleExpand(r)} style={{ cursor: "pointer" }}>
                    <td style={{ ...tableTd, textAlign: "center", color: T.slate500 }}>{isOpen ? "▾" : "▸"}</td>
                    <td style={tableTd}>{fmtDate(r.statement_ending_date)}</td>
                    <td style={{ ...tableTd, textAlign: "right" }}>${fmtMoney(r.adjusted_statement_balance)}</td>
                    <td style={{ ...tableTd, textAlign: "right" }}>${fmtMoney(r.prior_personal_funds)}</td>
                    <td style={{ ...tableTd, textAlign: "right", fontWeight: 700, color: isClean ? T.slate800 : "#7B241C" }}>
                      ${fmtMoney(diff)}
                    </td>
                    <td style={tableTd}>{r.emailed_to_agent_at ? `✓ ${fmtDate(r.emailed_to_agent_at)}` : "—"}</td>
                    <td style={tableTd} onClick={(e) => e.stopPropagation()}>
                      <div style={{ display: "flex", gap: 6, justifyContent: "flex-end" }}>
                        <button type="button" onClick={() => handleRecompute(r.id)} disabled={recomputingId === r.id}
                          style={{
                            padding: "4px 10px", borderRadius: 6, border: `1px solid ${T.slate300}`,
                            background: T.white, color: T.slate700, fontSize: 12, cursor: "pointer",
                          }}>
                          {recomputingId === r.id ? "…" : "Recompute"}
                        </button>
                        {!r.emailed_to_agent_at && (
                          <button type="button" onClick={() => handleSend(r)} disabled={sendingId === r.id}
                            style={{
                              padding: "4px 10px", borderRadius: 6,
                              border: `1px solid ${isClean ? T.blue : "#B03A2E"}`,
                              background: isClean ? T.blue : "#B03A2E",
                              color: T.white, fontSize: 12, fontWeight: 600,
                              cursor: "pointer",
                            }}>
                            {sendingId === r.id ? "…" : (isClean ? "Send to SF" : "Send anyway")}
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                  {isOpen && (
                    <tr>
                      <td colSpan={7} style={{ padding: "12px 20px 18px", background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
                        <div style={{
                          display: "grid",
                          gridTemplateColumns: "minmax(260px, 400px) 1fr",
                          gap: 20,
                        }}>
                          <div style={{ background: T.white, padding: 14, borderRadius: 8, border: `1px solid ${T.slate200}` }}>
                            <div style={{ fontSize: 12, fontWeight: 700, color: T.slate700, textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 10 }}>
                              Reconciliation waterfall
                            </div>
                            {waterfallRow("Statement ending balance", r.statement_ending_balance)}
                            {waterfallRow("− Outstanding checks", r.outstanding_checks_total, { sign: "minus" })}
                            {waterfallRow("− Outstanding SF EFTs", r.outstanding_sf_eft_total, { sign: "minus" })}
                            {waterfallRow("+ Outstanding deposits", r.outstanding_deposits_total, { sign: "plus" })}
                            {waterfallRow("+ Returned checks (unreimbursed)", r.returned_checks_unreimbursed, { sign: "plus" })}
                            {waterfallRow("= Adjusted statement balance", r.adjusted_statement_balance, { emphasize: true })}
                            {waterfallRow("− Prior month personal funds", r.prior_personal_funds, { sign: "minus" })}
                            {waterfallRow("+ Current bank service fees", r.current_bank_service_fees, { sign: "plus" })}
                            {waterfallRow("Difference to reconcile", r.difference_to_reconcile, { emphasize: true, negative: !isClean })}
                          </div>

                          <div style={{ background: T.white, padding: 14, borderRadius: 8, border: `1px solid ${T.slate200}` }}>
                            <div style={{ fontSize: 12, fontWeight: 700, color: T.slate700, textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 6 }}>
                              Explanation
                            </div>
                            <div style={{ fontSize: 13, color: T.slate800, whiteSpace: "pre-wrap", lineHeight: 1.5, marginBottom: 12 }}>
                              {r.explanation || <span style={{ color: T.slate500, fontStyle: "italic" }}>—</span>}
                            </div>
                            {r.actions_taken && (
                              <>
                                <div style={{ fontSize: 12, fontWeight: 700, color: T.slate700, textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 6 }}>
                                  Actions taken
                                </div>
                                <div style={{ fontSize: 13, color: T.slate800, whiteSpace: "pre-wrap", lineHeight: 1.5, marginBottom: 12 }}>
                                  {r.actions_taken}
                                </div>
                              </>
                            )}
                            <div style={{ fontSize: 11, color: T.slate500, borderTop: `1px solid ${T.slate100}`, paddingTop: 8 }}>
                              Reconciled {r.reconciled_at ? fmtDate(r.reconciled_at) : "—"}
                              {r.emailed_to_agent_at && ` · Emailed to SF ${fmtDate(r.emailed_to_agent_at)}`}
                              {r.emailed_to_agent_message_id && ` · msg ${r.emailed_to_agent_message_id.slice(0, 8)}…`}
                            </div>
                          </div>
                        </div>

                        <div style={{ marginTop: 16 }}>
                          <div style={{ fontSize: 12, fontWeight: 700, color: T.slate700, textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 6 }}>
                            Outstanding items as of {fmtDate(r.statement_ending_date)}
                            {details && !details.loading && !details.error && details.rows && (
                              <span style={{ color: T.slate500, fontWeight: 500 }}> ({details.rows.length})</span>
                            )}
                          </div>
                          {details?.loading && <div style={{ fontSize: 13, color: T.slate500 }}>Loading…</div>}
                          {details?.error && <div style={{ fontSize: 13, color: "#7B241C" }}>{details.error}</div>}
                          {details && !details.loading && !details.error && (details.rows || []).length === 0 && (
                            <div style={{ fontSize: 13, color: T.slate500, fontStyle: "italic" }}>No outstanding items — clean reconciliation.</div>
                          )}
                          {details && !details.loading && (details.rows || []).length > 0 && (
                            <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12, background: T.white, borderRadius: 8, overflow: "hidden", border: `1px solid ${T.slate200}` }}>
                              <thead>
                                <tr>
                                  <th style={{ ...tableTh, fontSize: 10 }}>Date</th>
                                  <th style={{ ...tableTh, fontSize: 10 }}>Type</th>
                                  <th style={{ ...tableTh, fontSize: 10 }}>Customer</th>
                                  <th style={{ ...tableTh, fontSize: 10 }}>Policy</th>
                                  <th style={{ ...tableTh, fontSize: 10, textAlign: "right" }}>Debit</th>
                                  <th style={{ ...tableTh, fontSize: 10, textAlign: "right" }}>Credit</th>
                                  <th style={{ ...tableTh, fontSize: 10 }}>Check#</th>
                                </tr>
                              </thead>
                              <tbody>
                                {details.rows.map(t => (
                                  <tr key={t.id}>
                                    <td style={{ ...tableTd, fontSize: 12 }}>{fmtDate(t.transaction_date)}</td>
                                    <td style={{ ...tableTd, fontSize: 12 }}>{t.transaction_type}</td>
                                    <td style={{ ...tableTd, fontSize: 12 }}>{t.customer_name || "—"}</td>
                                    <td style={{ ...tableTd, fontSize: 12 }}>{t.policy_type || "—"}</td>
                                    <td style={{ ...tableTd, fontSize: 12, textAlign: "right" }}>{t.debit_amount ? `$${fmtMoney(t.debit_amount)}` : ""}</td>
                                    <td style={{ ...tableTd, fontSize: 12, textAlign: "right" }}>{t.credit_amount ? `$${fmtMoney(t.credit_amount)}` : ""}</td>
                                    <td style={{ ...tableTd, fontSize: 12 }}>{t.transaction_number || ""}</td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                          )}
                          <div style={{ fontSize: 11, color: T.slate500, marginTop: 6, fontStyle: "italic" }}>
                            Outstanding list is current DB state filtered to on/before the statement ending date — best-effort, not a historical snapshot.
                          </div>
                        </div>
                      </td>
                    </tr>
                  )}
                </React.Fragment>
              );
            })}
          </tbody>
        </table>
      </div>
      <div style={{ fontSize: 11, color: T.slate500, marginTop: 8 }}>
        Clean reconciliations auto-send when the daily 12 PM CT recipe runs. Recompute updates the math against the current ledger. Send to SF fires the PDF + email manually (requires confirmation; discrepancies require a stronger confirmation).
      </div>
    </div>
  );
}

// =====================================================================
// ClosesTab
// =====================================================================
function ClosesTab() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [resendingId, setResendingId] = useState(null);
  const [resendMsg, setResendMsg] = useState("");

  const load = useCallback(async () => {
    setLoading(true); setError("");
    const { data, error } = await supabase
      .from("pfa_daily_closes")
      .select(`
        id, close_date, deposit_count, total_amount,
        telegram_send_ok, telegram_message_id, telegram_send_error,
        closed_at, closed_by_team_member_id
      `)
      .eq("agency_id", AGENCY_ID)
      .order("close_date", { ascending: false })
      .limit(100);
    if (error) setError(error.message);
    else setRows(data || []);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const [teamMap, setTeamMap] = useState(new Map());
  useEffect(() => {
    supabase.from("team").select("id, first_name").eq("agency_id", AGENCY_ID)
      .then(({ data }) => {
        const m = new Map();
        for (const t of data || []) m.set(t.id, t.first_name);
        setTeamMap(m);
      });
  }, []);

  const handleResend = async (row) => {
    setResendMsg("");
    if (!window.confirm(`Resend the team Telegram for ${fmtDate(row.close_date)}?`)) return;
    setResendingId(row.id);
    try {
      const { data, error: rpcErr } = await supabase.rpc("pfa_resend_close_telegram", { p_close_id: row.id });
      if (rpcErr) { setResendMsg(rpcErr.message || "Resend failed."); return; }
      setResendMsg(data?.ok ? "Resent." : `Resend attempted but not OK: ${data?.telegram_send_error || "unknown"}`);
      await load();
    } catch (e) {
      setResendMsg(String(e?.message || e));
    } finally {
      setResendingId(null);
    }
  };

  return (
    <div>
      {resendMsg && (
        <div style={{ marginBottom: 12, padding: "10px 12px", borderRadius: 8, background: T.slate50, border: `1px solid ${T.slate200}`, fontSize: 13, color: T.slate800 }}>
          {resendMsg}
        </div>
      )}
      <div style={{ ...cardStyle, padding: 0, overflowX: "auto" }}>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
          <thead>
            <tr>
              <th style={tableTh}>Date</th>
              <th style={tableTh}>Closed by</th>
              <th style={{ ...tableTh, textAlign: "right" }}>Deposits</th>
              <th style={{ ...tableTh, textAlign: "right" }}>Total</th>
              <th style={tableTh}>Telegram</th>
              <th style={tableTh}>Closed at</th>
              <th style={tableTh}></th>
            </tr>
          </thead>
          <tbody>
            {loading && <tr><td colSpan={7} style={{ ...tableTd, textAlign: "center", color: T.slate500 }}>Loading…</td></tr>}
            {!loading && error && <tr><td colSpan={7} style={{ ...tableTd, color: "#7B241C" }}>{error}</td></tr>}
            {!loading && !error && rows.length === 0 && (
              <tr><td colSpan={7} style={{ ...tableTd, textAlign: "center", color: T.slate500, fontStyle: "italic" }}>No closes recorded yet.</td></tr>
            )}
            {!loading && rows.map(r => (
              <tr key={r.id}>
                <td style={tableTd}>{fmtDate(r.close_date)}</td>
                <td style={tableTd}>{teamMap.get(r.closed_by_team_member_id) || "—"}</td>
                <td style={{ ...tableTd, textAlign: "right" }}>{r.deposit_count}</td>
                <td style={{ ...tableTd, textAlign: "right", fontWeight: 700 }}>${fmtMoney(r.total_amount)}</td>
                <td style={tableTd}>
                  {r.telegram_send_ok ? (
                    <span style={{ color: T.slate700 }}>✓ sent</span>
                  ) : (
                    <span style={{ color: "#7B241C" }} title={r.telegram_send_error || ""}>✗ failed</span>
                  )}
                </td>
                <td style={tableTd}>{fmtTime(r.closed_at)}</td>
                <td style={tableTd}>
                  {!r.telegram_send_ok && (
                    <button type="button" onClick={() => handleResend(r)} disabled={resendingId === r.id}
                      style={{
                        padding: "4px 10px", borderRadius: 6, border: `1px solid ${T.slate300}`,
                        background: T.white, color: T.slate700, fontSize: 12, cursor: "pointer",
                      }}>
                      {resendingId === r.id ? "…" : "Resend"}
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// =====================================================================
// Default export — role dispatch + tabs
// =====================================================================
export default function PFA({ userRole }) {
  const isAdmin = userRole === "owner" || userRole === "manager";
  const [activeTab, setActiveTab] = useState("today");
  const [pfaAccountId, setPfaAccountId] = useState(null);
  const [teamRoster, setTeamRoster] = useState([]);

  useEffect(() => {
    if (!isAdmin) return;
    supabase.from("pfa_accounts").select("id").eq("agency_id", AGENCY_ID).eq("is_active", true).maybeSingle()
      .then(({ data }) => setPfaAccountId(data?.id || null));
    supabase.from("team").select("id, first_name").eq("agency_id", AGENCY_ID)
      .is("archived_at", null).eq("is_admin_backoffice", false)
      .order("first_name")
      .then(({ data }) => setTeamRoster(data || []));
  }, [isAdmin]);

  const tabs = [
    { id: "today",   label: "Today" },
    { id: "ledger",  label: "Ledger" },
    { id: "statements", label: "Statements" },
    { id: "recon",   label: "Reconciliations" },
    { id: "closes",  label: "Closes" },
  ];

  return (
    <div style={{ flex: 1, background: T.slate50, padding: "24px 20px 40px", overflowY: "auto" }}>
      <div style={{ maxWidth: isAdmin ? 1100 : 560, margin: "0 auto" }}>
        {/* Header */}
        <div style={{ marginBottom: 20 }}>
          <div style={{ fontSize: 22, fontWeight: 800, color: T.slate900, lineHeight: 1.2 }}>
            Premium Fund Account
          </div>
          <div style={{ fontSize: 14, color: T.slate500, marginTop: 6, lineHeight: 1.5 }}>
            {isAdmin
              ? "Record deposits, review the ledger, and monitor monthly reconciliation."
              : "Record every customer premium payment (check, cash, transfer) taken today. Press Close Day when the deposit is done."}
          </div>
        </div>

        {/* Admin tabs */}
        {isAdmin && (
          <div style={{ display: "flex", gap: 4, marginBottom: 16, borderBottom: `1px solid ${T.slate200}`, flexWrap: "wrap" }}>
            {tabs.map(t => {
              const active = activeTab === t.id;
              return (
                <button key={t.id} type="button" onClick={() => setActiveTab(t.id)}
                  style={{
                    padding: "8px 14px",
                    borderRadius: "8px 8px 0 0",
                    border: "none",
                    borderBottom: `2px solid ${active ? T.blue : "transparent"}`,
                    background: "transparent",
                    color: active ? T.slate900 : T.slate500,
                    fontSize: 14,
                    fontWeight: active ? 700 : 500,
                    cursor: "pointer",
                    marginBottom: -1,
                  }}>
                  {t.label}
                </button>
              );
            })}
          </div>
        )}

        {/* Content */}
        {(!isAdmin || activeTab === "today") && <TeamEntryAndToday />}
        {isAdmin && activeTab === "ledger" && <LedgerTab pfaAccountId={pfaAccountId} teamRoster={teamRoster} />}
        {isAdmin && activeTab === "statements" && <StatementsTab pfaAccountId={pfaAccountId} />}
        {isAdmin && activeTab === "recon" && <ReconciliationsTab pfaAccountId={pfaAccountId} />}
        {isAdmin && activeTab === "closes" && <ClosesTab />}

        {!isAdmin && (
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 16, lineHeight: 1.5 }}>
            Deposits sync to the monthly PFA reconciliation. Ledger, statements, and reconciliations are visible to the agency owner only.
          </div>
        )}
      </div>
    </div>
  );
}
