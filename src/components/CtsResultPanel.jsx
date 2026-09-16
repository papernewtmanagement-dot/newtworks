import { useState, useEffect, useCallback } from "react";
import { supabase } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

// The CTS Sales Profile panel.
//
// Reading a result is the gate that opens the interview: nothing sends an
// interview invite until a result is on the candidate. The document processor
// records one automatically when the vendor's PDF arrives in the inbox. This
// panel is the other half — it shows what was recorded, and when the automatic
// read refuses (bad text, a name that matches nobody, two people with the same
// name) it is where the numbers get typed in by hand.
//
// Everything here goes through record_cts_result(). That function is the only
// writer of a result anywhere in the system: it is idempotent, it refuses a
// partial read, and stamping cts_completed_at is what fires the interview
// invite. This panel never writes a cts_ column directly and must not start.
//
// Keys below MUST match the ones the parser emits
// (supabase/functions/document-processor/parsers/cts_profile.ts). They are the
// vendor's own labels, snake_cased, in the vendor's own order. Do not rename
// one side without the other or the same report reads two different ways
// depending on which path recorded it.

const PRIMARY_TRAITS = [
  ["deadline_motivation", "Deadline Motivation"],
  ["recognition_drive", "Recognition Drive"],
  ["assertiveness", "Assertiveness"],
  ["independent_spirit", "Independent Spirit"],
  ["analytical", "Analytical"],
  ["compassion", "Compassion"],
  ["self_promotion", "Self-Promotion"],
  ["belief_in_others", "Belief in Others"],
  ["optimism", "Optimism"],
];

const SALES_COMPETENCIES = [
  ["maintains_high_activity", "Maintains High Activity"],
  ["handles_rejection", "Handles Rejection"],
  ["prospects_in_community", "Prospects in Community"],
  ["dials_cold_calls", "Dials / Cold Calls"],
  ["listens_discovers_needs", "Listens / Discovers Needs"],
  ["presents_solutions", "Presents Solutions"],
  ["gets_decisions_handles_objections_referrals", "Gets Decisions / Handles Objections / Referrals"],
  ["receives_coaching", "Receives Coaching"],
  ["positively_influences_team", "Positively Influences Team"],
];

const LSS_SECTIONS = [
  ["math", "Math"],
  ["verbal", "Verbal"],
  ["problem_solving", "Problem Solving"],
];

const VALIDITY = ["low", "moderate", "high"];

function toNum(v) {
  if (v === "" || v === null || v === undefined) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

const labelStyle = { fontSize: 10, color: T.slate600, display: "block", marginBottom: 2 };
const inputStyle = {
  width: "100%", padding: "5px 6px", fontSize: 12.5, borderRadius: 5,
  border: `1px solid ${T.slate200}`, boxSizing: "border-box",
};

function NumField({ label, value, onChange, placeholder }) {
  return (
    <div>
      <label style={labelStyle}>{label}</label>
      <input
        type="number" inputMode="numeric" value={value ?? ""} placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)} style={inputStyle}
      />
    </div>
  );
}

function Grid({ cols, children }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`, gap: 8 }}>
      {children}
    </div>
  );
}

function Chip({ label, value }) {
  return (
    <div style={{
      padding: "5px 9px", borderRadius: 6, background: T.slate50,
      border: `1px solid ${T.slate200}`, minWidth: 74,
    }}>
      <div style={{ fontSize: 9, color: T.slate500, textTransform: "uppercase", letterSpacing: 0.3 }}>{label}</div>
      <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{value ?? "—"}</div>
    </div>
  );
}

function ScoreRows({ pairs, values }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "1fr auto", rowGap: 3, columnGap: 10 }}>
      {pairs.map(([k, label]) => (
        <ScoreRow key={k} label={label} value={values?.[k]} />
      ))}
    </div>
  );
}

function ScoreRow({ label, value }) {
  return (
    <>
      <div style={{ fontSize: 11.5, color: T.slate700 }}>{label}</div>
      <div style={{ fontSize: 11.5, fontWeight: 700, color: value == null ? T.slate500 : T.slate900 }}>
        {value == null ? "—" : Math.round(Number(value))}
      </div>
    </>
  );
}

export default function CtsResultPanel({ candidateId, isPhone }) {
  const [row, setRow] = useState(null);
  const [loadError, setLoadError] = useState(false);
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);
  const [form, setForm] = useState({
    cts_score: "", ego_drive: "", empathy: "",
    reliability: "", response_distortion: "",
    traits: {}, comps: {}, acc: {}, speed: {}, acc_total: "",
  });

  const load = useCallback(async () => {
    if (!candidateId || !supabase) return;
    const { data, error } = await supabase
      .from("hiring_candidates")
      .select("cts_invite_sent_at, cts_completed_at, cts_source, cts_recorded_by, cts_result")
      .eq("id", candidateId)
      .maybeSingle();
    if (error) { setLoadError(true); return; }
    setLoadError(false);
    setRow(data || null);
  }, [candidateId]);

  useEffect(() => { load(); }, [load]);

  const setPart = (part, key, value) =>
    setForm((f) => ({ ...f, [part]: { ...f[part], [key]: value } }));

  const traitCount = PRIMARY_TRAITS.filter(([k]) => toNum(form.traits[k]) !== null).length;

  const save = async () => {
    setSaving(true);
    setSaveError(null);

    const traits = {};
    for (const [k] of PRIMARY_TRAITS) traits[k] = toNum(form.traits[k]);
    const comps = {};
    for (const [k] of SALES_COMPETENCIES) comps[k] = toNum(form.comps[k]);

    const lss_accuracy = {};
    const lss_speed = {};
    for (const [k] of LSS_SECTIONS) {
      const a = toNum(form.acc[k]);
      if (a !== null) lss_accuracy[k] = { candidate: a };
      const s = toNum(form.speed[k]);
      if (s !== null) lss_speed[k] = { candidate: s };
    }
    const total = toNum(form.acc_total);
    if (total !== null) lss_accuracy.total = { candidate: total };

    const payload = {
      cts_score: toNum(form.cts_score),
      ego_drive: toNum(form.ego_drive),
      empathy: toNum(form.empathy),
      reliability: form.reliability || null,
      response_distortion: form.response_distortion || null,
      primary_traits: traits,
      sales_competencies: comps,
      lss_accuracy,
      lss_speed,
      entered_at: new Date().toISOString(),
    };

    const { data, error } = await supabase.rpc("record_cts_result", {
      p_candidate_id: candidateId,
      p_payload: payload,
      p_source: "manual",
      p_recorded_by: "candidate page",
    });
    setSaving(false);
    if (error) { setSaveError(error.message); return; }
    if (!data?.ok) { setSaveError(data?.error || "The result was not recorded."); return; }
    setOpen(false);
    load();
  };

  const recorded = !!row?.cts_completed_at;
  const result = row?.cts_result || null;
  const cols = isPhone ? 2 : 3;

  return (
    <div>
      {loadError && (
        <div style={{ fontSize: 11.5, color: T.slate600 }}>
          Could not load the CTS result for this candidate.
        </div>
      )}

      {!loadError && !recorded && (
        <div>
          <div style={{ fontSize: 12, color: T.slate600, marginBottom: 8, lineHeight: 1.5 }}>
            {row?.cts_invite_sent_at
              ? `Sales profile sent ${new Date(row.cts_invite_sent_at).toLocaleDateString()}. No result yet.`
              : "No sales profile sent yet."}
            {" "}The result is recorded automatically when the report arrives by email.
            The interview invite goes out once it is.
          </div>
          {!open && (
            <button
              onClick={() => setOpen(true)}
              style={{
                padding: "7px 14px", fontSize: 12, fontWeight: 600, color: T.white,
                background: T.blue, border: "none", borderRadius: 7, cursor: "pointer",
              }}
            >
              Record CTS Result
            </button>
          )}
        </div>
      )}

      {open && !recorded && (
        <div style={{ marginTop: 10, display: "flex", flexDirection: "column", gap: 14 }}>
          <div style={{ fontSize: 11.5, color: T.slate600, lineHeight: 1.5 }}>
            Type in what the report shows. The nine primary traits are the only
            part that has to be filled in — leave anything the report does not
            give you blank.
          </div>

          <Grid cols={cols}>
            <NumField label="CTS score" value={form.cts_score} onChange={(v) => setForm((f) => ({ ...f, cts_score: v }))} />
            <NumField label="Ego drive" value={form.ego_drive} onChange={(v) => setForm((f) => ({ ...f, ego_drive: v }))} />
            <NumField label="Empathy" value={form.empathy} onChange={(v) => setForm((f) => ({ ...f, empathy: v }))} />
            <div>
              <label style={labelStyle}>Reliability</label>
              <select value={form.reliability} onChange={(e) => setForm((f) => ({ ...f, reliability: e.target.value }))} style={inputStyle}>
                <option value="">—</option>
                {VALIDITY.map((v) => <option key={v} value={v}>{v}</option>)}
              </select>
            </div>
            <div>
              <label style={labelStyle}>Response distortion</label>
              <select value={form.response_distortion} onChange={(e) => setForm((f) => ({ ...f, response_distortion: e.target.value }))} style={inputStyle}>
                <option value="">—</option>
                {VALIDITY.map((v) => <option key={v} value={v}>{v}</option>)}
              </select>
            </div>
          </Grid>

          <div>
            <div style={{ fontSize: 11, fontWeight: 700, color: T.slate700, marginBottom: 6 }}>
              Primary traits <span style={{ fontWeight: 500, color: T.slate500 }}>({traitCount} of 9 filled in, 7 needed)</span>
            </div>
            <Grid cols={cols}>
              {PRIMARY_TRAITS.map(([k, label]) => (
                <NumField key={k} label={label} value={form.traits[k]} onChange={(v) => setPart("traits", k, v)} />
              ))}
            </Grid>
          </div>

          <div>
            <div style={{ fontSize: 11, fontWeight: 700, color: T.slate700, marginBottom: 6 }}>Sales competencies</div>
            <Grid cols={cols}>
              {SALES_COMPETENCIES.map(([k, label]) => (
                <NumField key={k} label={label} value={form.comps[k]} onChange={(v) => setPart("comps", k, v)} />
              ))}
            </Grid>
          </div>

          <div>
            <div style={{ fontSize: 11, fontWeight: 700, color: T.slate700, marginBottom: 6 }}>
              Learning style — the candidate's own numbers
            </div>
            <Grid cols={cols}>
              {LSS_SECTIONS.map(([k, label]) => (
                <NumField key={`a-${k}`} label={`${label} correct`} value={form.acc[k]} onChange={(v) => setPart("acc", k, v)} />
              ))}
              <NumField label="Total correct (of 35)" value={form.acc_total} onChange={(v) => setForm((f) => ({ ...f, acc_total: v }))} />
              {LSS_SECTIONS.map(([k, label]) => (
                <NumField key={`s-${k}`} label={`${label} seconds`} value={form.speed[k]} onChange={(v) => setPart("speed", k, v)} />
              ))}
            </Grid>
          </div>

          {saveError && (
            <div style={{ fontSize: 11.5, color: T.red }}>{saveError}</div>
          )}

          <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
            <button
              onClick={save}
              disabled={saving || traitCount < 7}
              style={{
                padding: "7px 14px", fontSize: 12, fontWeight: 600, color: T.white,
                background: traitCount < 7 ? T.slate500 : T.blue, border: "none", borderRadius: 7,
                cursor: saving ? "wait" : traitCount < 7 ? "not-allowed" : "pointer",
              }}
            >
              {saving ? "Saving..." : "Save CTS Result"}
            </button>
            <button
              onClick={() => { setOpen(false); setSaveError(null); }}
              style={{
                padding: "7px 14px", fontSize: 12, fontWeight: 600, color: T.slate700,
                background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 7, cursor: "pointer",
              }}
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {recorded && (
        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            <Chip label="CTS" value={result?.cts_score} />
            <Chip label="Ego drive" value={result?.ego_drive} />
            <Chip label="Empathy" value={result?.empathy} />
            <Chip label="Reliability" value={result?.reliability} />
            <Chip label="Distortion" value={result?.response_distortion} />
          </div>

          <div style={{
            display: "grid",
            gridTemplateColumns: isPhone ? "1fr" : "1fr 1fr",
            gap: isPhone ? 12 : 22,
          }}>
            <div>
              <div style={{ fontSize: 11, fontWeight: 700, color: T.slate700, marginBottom: 5 }}>Primary traits</div>
              <ScoreRows pairs={PRIMARY_TRAITS} values={result?.primary_traits} />
            </div>
            <div>
              <div style={{ fontSize: 11, fontWeight: 700, color: T.slate700, marginBottom: 5 }}>Sales competencies</div>
              <ScoreRows pairs={SALES_COMPETENCIES} values={result?.sales_competencies} />
            </div>
          </div>

          {(result?.lss_accuracy || result?.lss_speed) && (
            <div>
              <div style={{ fontSize: 11, fontWeight: 700, color: T.slate700, marginBottom: 5 }}>Learning style</div>
              <div style={{ fontSize: 11.5, color: T.slate800, lineHeight: 1.7 }}>
                {LSS_SECTIONS.map(([k, label]) => {
                  const a = result?.lss_accuracy?.[k]?.candidate;
                  const s = result?.lss_speed?.[k]?.candidate;
                  if (a == null && s == null) return null;
                  return (
                    <div key={k}>
                      {label}: {a == null ? "—" : `${a} correct`}
                      {s == null ? "" : `, ${s} seconds`}
                    </div>
                  );
                })}
                {result?.lss_accuracy?.total?.candidate != null && (
                  <div>Total: {result.lss_accuracy.total.candidate} correct of 35</div>
                )}
              </div>
            </div>
          )}

          <div style={{ fontSize: 10, color: T.slate500 }}>
            Recorded {new Date(row.cts_completed_at).toLocaleString()}
            {row.cts_source === "manual" ? " by hand" : " from the emailed report"}
            {row.cts_recorded_by ? ` (${row.cts_recorded_by})` : ""}
          </div>
        </div>
      )}
    </div>
  );
}
