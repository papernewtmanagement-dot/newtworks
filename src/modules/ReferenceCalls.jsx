import { useCallback, useEffect, useState } from "react";
import { supabase } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";

// =========================================================================
// ReferenceCalls.jsx
// =========================================================================
// The calling list for whoever is checking a candidate's references.
//
// Everything on this page comes from rp_reference_calls(), which returns only
// the candidates assigned to the signed-in person. An admin gets all of them,
// which is how Peter reads the same list to see whether the calling is done.
//
// Logging a call goes through rp_reference_log_call(). A call that gets
// answered files its write-up in the SAME table as an emailed reference, so
// the one scorer (reference_is_positive, reached through
// hiring_reference_progress) decides whether it counts. Nothing on this page
// works out whether a reference is good.
// =========================================================================

const RESULTS = [
  { key: "reached",      label: "Reached them" },
  { key: "no_answer",    label: "No answer" },
];

const QUIET_RESULTS = [
  { key: "left_message", label: "left a message" },
  { key: "bad_number",   label: "bad number" },
  { key: "declined",     label: "would not talk" },
];

const OUTCOME_LABEL = {
  pending:           "Still to call",
  reached:           "Spoke to them",
  unreachable:       "Could not reach",
  declined_to_speak: "Would not talk",
};

const OUTCOME_COLOR = {
  pending:           { bg: T.slate100, fg: T.slate600 },
  reached:           { bg: T.greenLt,  fg: T.slate900 },
  unreachable:       { bg: T.amberLt,  fg: T.slate900 },
  declined_to_speak: { bg: T.amberLt,  fg: T.slate900 },
};

const WRITEUP_PROMPT =
  "Type what they said, in their words where you can. How they know the candidate, "
  + "what the candidate is good at, where they struggled, whether they would hire them "
  + "again, and anything the referee would not answer.";

function fmtDate(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

function Pill({ children, bg, fg }) {
  return (
    <span style={{
      display: "inline-block", padding: "2px 8px", borderRadius: 999,
      fontSize: 11, fontWeight: 600, background: bg, color: fg,
      boxSizing: "border-box", whiteSpace: "nowrap",
    }}>{children}</span>
  );
}

export default function ReferenceCalls() {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";

  const [rows, setRows] = useState(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState("");
  const [openForm, setOpenForm] = useState(null);   // contact id with the write-up box open
  const [draft, setDraft] = useState("");
  const [openTries, setOpenTries] = useState(null); // contact id whose attempt history is showing

  const load = useCallback(async () => {
    setError("");
    const { data, error: err } = await supabase.rpc("rp_reference_calls");
    if (err) { setError(err.message); setRows([]); return; }
    setRows(Array.isArray(data?.rows) ? data.rows : []);
  }, []);

  useEffect(() => { load(); }, [load]);

  const logCall = async (contactId, result, notes) => {
    setBusy(contactId + result);
    setError("");
    const { error: err } = await supabase.rpc("rp_reference_log_call", {
      p_contact_id: contactId, p_result: result, p_notes: notes || null,
    });
    setBusy("");
    if (err) { setError(err.message); return; }
    setOpenForm(null);
    setDraft("");
    await load();
  };

  const saveWriteup = async (contactId, body) => {
    setBusy(contactId + "save");
    setError("");
    const { error: err } = await supabase.rpc("rp_reference_save_writeup", {
      p_contact_id: contactId, p_body: body,
    });
    setBusy("");
    if (err) { setError(err.message); return; }
    setOpenForm(null);
    setDraft("");
    await load();
  };

  const card = {
    background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12,
    padding: _vp.isPhone ? 14 : 18, boxSizing: "border-box",
  };
  const btn = {
    padding: "7px 12px", borderRadius: 8, border: `1px solid ${T.slate300}`,
    background: T.white, color: T.slate700, fontSize: 13, fontWeight: 600,
    cursor: "pointer", boxSizing: "border-box",
  };
  const btnMain = { ...btn, background: T.blue, borderColor: T.blue, color: T.white };
  const quiet = {
    background: "none", border: "none", padding: 0, color: T.slate500,
    fontSize: 12, cursor: "pointer", textDecoration: "underline",
  };

  return (
    <div style={{ padding: _pad, display: "flex", flexDirection: "column", gap: 16 }}>
      <div>
        <h1 style={{ margin: 0, fontSize: 22, fontWeight: 700, color: T.slate900 }}>
          Reference calls
        </h1>
        <p style={{ margin: "4px 0 0", fontSize: 13, color: T.slate500, lineHeight: 1.5 }}>
          Log every call, including the ones nobody picks up. After three tries on a number
          we email the candidate and ask them to get that person to call you back.
        </p>
      </div>

      {error && (
        <div style={{ ...card, background: T.redLt, borderColor: T.red, color: T.slate900, fontSize: 13 }}>
          {error}
        </div>
      )}

      {rows === null && (
        <div style={{ ...card, color: T.slate500, fontSize: 13 }}>Loading…</div>
      )}

      {rows !== null && rows.length === 0 && (
        <div style={{ ...card, color: T.slate500, fontSize: 13 }}>
          Nothing to call right now. This fills up when a candidate accepts an offer
          and gives us their references.
        </div>
      )}

      {(rows || []).map((r) => {
        const prog = r.progress || {};
        const need = prog.minimum ?? 2;
        const got = prog.positive ?? 0;
        const contacts = Array.isArray(r.contacts) ? r.contacts : [];

        return (
          <div key={r.candidate_id} style={{ ...card, display: "flex", flexDirection: "column", gap: 14 }}>

            <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "baseline", justifyContent: "space-between" }}>
              <div>
                <div style={{ fontSize: 17, fontWeight: 700, color: T.slate900 }}>
                  {r.candidate_name}
                </div>
                <div style={{ fontSize: 12, color: T.slate500, marginTop: 2 }}>
                  {r.offer_job_title || "New hire"}
                  {r.offer_start_date ? ` · starts ${fmtDate(r.offer_start_date)}` : ""}
                  {r.caller_label ? ` · calls by ${r.caller_label}` : ""}
                </div>
              </div>
              <Pill
                bg={got >= need ? T.greenLt : T.slate100}
                fg={got >= need ? T.slate900 : T.slate600}
              >
                {got} of {need} good references
              </Pill>
            </div>

            {r.reference_paused_at && (
              <div style={{ background: T.redLt, borderRadius: 8, padding: 10, fontSize: 13, color: T.slate900, boxSizing: "border-box" }}>
                <b>Paused.</b> {r.reference_paused_reason}
              </div>
            )}

            {!r.reference_paused_at && r.reference_help_email_sent_at && (
              <div style={{ background: T.amberLt, borderRadius: 8, padding: 10, fontSize: 13, color: T.slate900, boxSizing: "border-box" }}>
                {r.candidate_name} was emailed on {fmtDate(r.reference_help_email_sent_at)} and
                asked to tell these people we are calling.
                {r.reference_final_email_sent_at
                  ? " A final email has gone out too."
                  : r.reference_round2_opens_at
                    ? ` We try again from ${fmtDate(r.reference_round2_opens_at)}.`
                    : ""}
              </div>
            )}

            <div style={{ display: "grid", gap: 10, gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))" }}>
              {contacts.map((c) => {
                const oc = OUTCOME_COLOR[c.outcome] || OUTCOME_COLOR.pending;
                const tries = Array.isArray(c.attempts) ? c.attempts : [];
                const formOpen = openForm === c.id;

                return (
                  <div key={c.id} style={{
                    border: `1px solid ${T.slate200}`, borderRadius: 10, padding: 12,
                    display: "flex", flexDirection: "column", gap: 8, boxSizing: "border-box",
                  }}>
                    <div style={{ display: "flex", flexWrap: "wrap", gap: 8, justifyContent: "space-between", alignItems: "baseline" }}>
                      <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>
                        {c.name}
                      </div>
                      <Pill bg={oc.bg} fg={oc.fg}>{OUTCOME_LABEL[c.outcome] || c.outcome}</Pill>
                    </div>

                    {(c.relationship || c.company) && (
                      <div style={{ fontSize: 12, color: T.slate500 }}>
                        {[c.relationship, c.company].filter(Boolean).join(" at ")}
                      </div>
                    )}

                    <div style={{ display: "flex", flexWrap: "wrap", gap: 10, fontSize: 13 }}>
                      {c.phone && (
                        <a href={`tel:${c.phone}`} style={{ color: T.blue, fontWeight: 600, textDecoration: "none" }}>
                          {c.phone}
                        </a>
                      )}
                      {c.email && (
                        <a href={`mailto:${c.email}`} style={{ color: T.blue, textDecoration: "none" }}>
                          {c.email}
                        </a>
                      )}
                    </div>

                    <div style={{ fontSize: 12, color: T.slate500 }}>
                      {c.attempt_count === 0
                        ? "Not tried yet"
                        : `${c.attempt_count} ${c.attempt_count === 1 ? "try" : "tries"}`}
                      {c.round > 1 ? " · second round" : ""}
                      {c.last_attempt_at ? ` · last ${fmtDate(c.last_attempt_at)}` : ""}
                      {tries.length > 0 && (
                        <>
                          {" · "}
                          <button
                            type="button"
                            style={quiet}
                            onClick={() => setOpenTries(openTries === c.id ? null : c.id)}
                          >
                            {openTries === c.id ? "hide" : "show"}
                          </button>
                        </>
                      )}
                    </div>

                    {openTries === c.id && (
                      <div style={{ fontSize: 12, color: T.slate600, display: "flex", flexDirection: "column", gap: 2 }}>
                        {tries.map((a, i) => (
                          <div key={i}>
                            {String(a?.at || "").replace("T", " ")} — {String(a?.result || "").replace(/_/g, " ")}
                            {a?.by ? ` (${a.by})` : ""}
                          </div>
                        ))}
                      </div>
                    )}

                    {c.writeup && !formOpen && (
                      <div style={{ background: T.slate50, borderRadius: 8, padding: 10, boxSizing: "border-box" }}>
                        <div style={{ fontSize: 12, color: T.slate700, whiteSpace: "pre-wrap", lineHeight: 1.5 }}>
                          {c.writeup}
                        </div>
                        <div style={{ marginTop: 8, display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center" }}>
                          {c.scored
                            ? <Pill bg={c.positive ? T.greenLt : T.amberLt} fg={T.slate900}>
                                {c.positive ? "Counts as a good reference" : "Does not count"}
                              </Pill>
                            : <Pill bg={T.slate100} fg={T.slate600}>Not scored yet</Pill>}
                          <button
                            type="button"
                            style={quiet}
                            onClick={() => { setOpenForm(c.id); setDraft(c.writeup || ""); }}
                          >
                            edit
                          </button>
                        </div>
                      </div>
                    )}

                    {formOpen && (
                      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                        <textarea
                          value={draft}
                          onChange={(e) => setDraft(e.target.value)}
                          placeholder={WRITEUP_PROMPT}
                          rows={8}
                          style={{
                            width: "100%", maxWidth: "100%", boxSizing: "border-box",
                            padding: 10, borderRadius: 8, border: `1px solid ${T.slate300}`,
                            fontSize: 13, fontFamily: "inherit", lineHeight: 1.5, resize: "vertical",
                          }}
                        />
                        <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
                          <button
                            type="button"
                            style={btnMain}
                            disabled={busy !== "" || draft.trim() === ""}
                            onClick={() => (c.writeup
                              ? saveWriteup(c.id, draft)
                              : logCall(c.id, "reached", draft))}
                          >
                            {busy !== "" ? "Saving…" : "Save what they said"}
                          </button>
                          <button
                            type="button"
                            style={btn}
                            onClick={() => { setOpenForm(null); setDraft(""); }}
                          >
                            Cancel
                          </button>
                        </div>
                      </div>
                    )}

                    {!formOpen && !c.writeup && (
                      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                        <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
                          {RESULTS.map((res) => (
                            <button
                              key={res.key}
                              type="button"
                              style={res.key === "reached" ? btnMain : btn}
                              disabled={busy !== ""}
                              onClick={() => {
                                if (res.key === "reached") { setOpenForm(c.id); setDraft(""); }
                                else logCall(c.id, res.key, null);
                              }}
                            >
                              {res.label}
                            </button>
                          ))}
                        </div>
                        <div style={{ display: "flex", flexWrap: "wrap", gap: 12 }}>
                          {QUIET_RESULTS.map((res) => (
                            <button
                              key={res.key}
                              type="button"
                              style={quiet}
                              disabled={busy !== ""}
                              onClick={() => logCall(c.id, res.key, null)}
                            >
                              {res.label}
                            </button>
                          ))}
                        </div>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
        );
      })}
    </div>
  );
}
