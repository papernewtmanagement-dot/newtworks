import { useState, useEffect, useCallback, useRef } from "react";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import GmaPatternItem, { isGmaPatternItem } from "../components/GmaPatternItem.jsx";
import GmaNumericalItem, { isGmaNumericalItem } from "../components/GmaNumericalItem.jsx";
// NOTE: This module intentionally does NOT import from ../lib/supabase.js.
// Per Newtworks v1 access model (session_note 2026-07-28 step 10.1), the
// public /assess/* route never instantiates a Supabase client — the edge
// function v1-assessment is the sole DB gateway. HMAC token in the URL is
// the auth mechanism; DB privileges live only inside the edge fn via
// service role. Do not "fix" the missing supabase import.

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL || "";
const SUPABASE_ANON = import.meta.env.VITE_SUPABASE_ANON_KEY || "";
const V1_ENDPOINT = `${SUPABASE_URL}/functions/v1/v1-assessment`;

const LIKERT_LABELS = [
  { value: 1, label: "Strongly disagree" },
  { value: 2, label: "Disagree" },
  { value: 3, label: "Neutral" },
  { value: 4, label: "Agree" },
  { value: 5, label: "Strongly agree" },
];

async function callV1(candidateId, token, action, extra = {}) {
  const body = { candidate_id: candidateId, token, action, ...extra };
  const headers = { "Content-Type": "application/json" };
  if (SUPABASE_ANON) {
    headers["Authorization"] = `Bearer ${SUPABASE_ANON}`;
    headers["apikey"] = SUPABASE_ANON;
  }
  try {
    const res = await fetch(V1_ENDPOINT, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({ error: "invalid_response" }));
    return { ok: res.ok, status: res.status, data };
  } catch (e) {
    return { ok: false, status: 0, data: { error: "network_error", detail: String(e?.message || e) } };
  }
}

// Sort choices so any "None of these" option sits last (VCT convention).
function orderChoices(choices) {
  if (!Array.isArray(choices)) return [];
  const out = [...choices];
  const idx = out.findIndex(
    (c) => typeof c === "string" && c.toLowerCase().includes("none of these")
  );
  if (idx !== -1 && idx !== out.length - 1) {
    const [none] = out.splice(idx, 1);
    out.push(none);
  }
  return out;
}

// Personality and impression-management items are stored as IPIP fragments
// ("Enjoy silence.", "Am the life of the party.", "Believe there is never an
// excuse for lying."). Render them to the candidate as first-person statements
// so it's obvious they're being asked to reflect on themselves. Cognitive and
// validity items are already full sentences — pass them through untouched.
function formatItemText(item) {
  if (!item) return "";
  // GMA pattern items store their generator's internal rule description in
  // item_text (e.g. "Shape steps circle->square->triangle left to right").
  // That is QA/authoring metadata, not candidate-facing copy — it names the
  // solving rule outright. GmaPatternItem renders its own fixed instruction
  // instead; never surface item_text for this item type.
  if (isGmaPatternItem(item)) return "";
  // GMA numerical items ask a plain instruction ("figure out the rule") that
  // is safe to show, but GmaNumericalItem renders its own fixed instruction
  // for consistency with the pattern-matching item type -- skip item_text
  // here too so the two GMA subtests behave identically.
  if (isGmaNumericalItem(item)) return "";
  const text = item.item_text || "";
  if (!text) return text;
  // Vocabulary / validity checks live in the personality section but are real
  // multiple-choice questions ("What does the word X mean?"), not IPIP
  // fragments — prefixing produced "I what does the word …" (caught in the
  // 2026-08-05 self-test). Anything carrying a choices payload is a full
  // question: never prefix it.
  if (item.choices != null) return text;
  const isSelfDescriptive =
    item.section === "newtworks_v1_personality" ||
    item.section === "newtworks_v1_impression_mgmt" ||
    item.section === "newtworks_v2_personality";
  if (!isSelfDescriptive) return text;
  return "I " + text.charAt(0).toLowerCase() + text.slice(1);
}

export default function CandidateAssessment({ candidateId, token }) {
  const vp = useViewport();

  const [screen, setScreen] = useState("loading");
  const [fatalError, setFatalError] = useState(null);
  const [saveError, setSaveError] = useState(null);
  const [candidate, setCandidate] = useState(null);
  const [items, setItems] = useState([]);
  const [currentIdx, setCurrentIdx] = useState(0);
  const [overall, setOverall] = useState({ answered: 0, total: 0 });
  const [batchProgress, setBatchProgress] = useState({ answered: 0, total: 0 });
  const [stint, setStint] = useState(1);
  const [saving, setSaving] = useState(false);

  // Per-item shown-at timestamp captured on the FRONTEND at the moment the
  // candidate actually sees a new question. Sent as served_at on save_response.
  // Fixes the pre-v10 bug where a single batch-level served_at (set when the
  // whole batch was fetched) produced nonsense per-item response times — a
  // candidate reading through 100 items over 10 minutes was previously
  // credited with 600 s on the last item and ~0 s on the first, when the real
  // per-item read/answer time is 4-10 s. Ref (not state) because we don't need
  // a re-render on capture; the value is only read inside handleAnswer.
  const shownAtRef = useRef(null);
  useEffect(() => {
    if (
      (screen === "primary" || screen === "expansion") &&
      items.length > 0 &&
      currentIdx < items.length
    ) {
      shownAtRef.current = new Date().toISOString();
    }
  }, [currentIdx, items, screen]);

  // Fetch + render items for whichever stint is next; if server says done, finalize.
  const runServe = useCallback(async () => {
    setScreen("loading");
    const { ok, data } = await callV1(candidateId, token, "serve");
    if (!ok) {
      setFatalError(data?.error || "Failed to load assessment items.");
      setScreen("error");
      return;
    }
    if (data.done) {
      const fin = await callV1(candidateId, token, "finalize");
      if (!fin.ok) {
        setFatalError(fin.data?.error || "Failed to finalize.");
        setScreen("error");
        return;
      }
      setScreen("thanks");
      return;
    }
    setStint(data.stint || 1);
    setItems(Array.isArray(data.items) ? data.items : []);
    setBatchProgress(data.progress || { answered: 0, total: 0 });
    setCurrentIdx(0);
    setSaveError(null);
    // On first entry into stint 2, show an informational intro screen with a
    // Continue button so the candidate understands why extra questions appeared.
    // Resumed mid-stint-2 sessions (progress.answered > 0) skip straight to
    // the questions.
    // Break screen fires before EVERY stint beyond the first (stint 2 or 3,
    // v2 can have both), not just stint 2 — v2 assessment Step 5 (Ass Fix 5
    // break-screen spec: rest suggestion, no countdown timer, one per stint
    // boundary). Resumed mid-stint sessions (progress.answered > 0) skip the
    // break and go straight to the questions.
    if (
      data.stint > 1 &&
      Array.isArray(data.items) &&
      data.items.length > 0 &&
      (data.progress?.answered ?? 0) === 0
    ) {
      setScreen("expansion_intro");
    } else {
      setScreen(data.stint > 1 ? "expansion" : "primary");
    }
  }, [candidateId, token]);

  // Initial verify + branch.
  useEffect(() => {
    if (!candidateId || !token) {
      setFatalError("This link is missing required information.");
      setScreen("error");
      return;
    }
    let cancelled = false;
    (async () => {
      const { ok, data } = await callV1(candidateId, token, "verify");
      if (cancelled) return;
      if (!ok) {
        const msg =
          data?.error === "invalid_token"
            ? "This link is not valid or has expired. Please contact the person who sent it to you."
            : data?.error === "candidate_not_found"
            ? "We couldn't find this assessment. Please contact the person who sent you this link."
            : "Something went wrong loading this assessment. Please try again in a moment.";
        setFatalError(msg);
        setScreen("error");
        return;
      }
      setCandidate(data?.candidate || {});
      setOverall(data?.progress || { answered: 0, total: 0 });

      const answered = data?.progress?.answered ?? 0;
      // An exit-gated candidate is reported by the server as done with a zero
      // progress count, so branching on the count alone dropped them onto the
      // "begin your assessment" screen — they clicked start and were thanked a
      // second later. Honour the server's done flag first: the neutral
      // completion screen is the intended treatment for a silent exit, same as
      // for anyone who genuinely finished (see the exit-gate note in the
      // v1-assessment edge function).
      if (data?.done) {
        setScreen("thanks");
      } else if (answered === 0) {
        setScreen("welcome");
      } else {
        // Resume mid-flow (primary partial, primary→expansion, or wrapping up).
        await runServe();
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [candidateId, token, runServe]);

  const handleAnswer = useCallback(
    async (payload) => {
      if (saving) return;
      const item = items[currentIdx];
      if (!item) return;
      setSaving(true);
      setSaveError(null);
      const body = { item_id: item.id };
      if (payload.value != null) body.response_value = payload.value;
      if (payload.label != null) body.response_label = payload.label;
      // Send the per-item shown-at time captured by the effect above. That is
      // the moment the candidate actually saw this specific question, so
      // (answered_at - served_at) is real per-item response time. Edge fn
      // tolerates missing served_at (drops to NULL) if this ever fails.
      if (shownAtRef.current != null) body.served_at = shownAtRef.current;
      const { ok, data } = await callV1(candidateId, token, "save_response", body);
      setSaving(false);
      if (!ok) {
        setSaveError(
          data?.error === "network_error"
            ? "Connection hiccup. Tap your answer again to retry."
            : "Save didn't go through. Tap your answer again to retry."
        );
        return;
      }
      // Advance both counters and index.
      setOverall((p) => ({ ...p, answered: p.answered + 1 }));
      setBatchProgress((p) => ({ ...p, answered: p.answered + 1 }));
      if (currentIdx + 1 < items.length) {
        setCurrentIdx(currentIdx + 1);
        return;
      }
      // Batch complete. ALWAYS re-serve rather than finalizing directly —
      // v2 can have a Stint 3 after Stint 2 (ambiguous-facet expansion), and
      // only the server knows whether another stint is pending. runServe()
      // itself calls finalize once the server reports done:true. (Fixed
      // 2026-08-01 v2 assessment Step 5: the old stint===1-only branch
      // finalized right after Stint 2 for every candidate, which meant any
      // v2 candidate who triggered a Stint 3 expansion got silently cut off
      // and hit a hard error, since the backend finalize gate rejects an
      // incomplete Stint 3.)
      setScreen("loading");
      await runServe();
    },
    [saving, items, currentIdx, candidateId, token, stint, runServe]
  );

  // ── Shared styles ─────────────────────────────────────────────
  const container = {
    minHeight: "100vh",
    background: T.slate50,
    padding: vp.isPhone ? "16px" : vp.isTablet ? "24px" : "32px",
    fontFamily:
      "system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif",
    color: T.slate900,
    boxSizing: "border-box",
  };
  const card = {
    maxWidth: 680,
    margin: "0 auto",
    background: T.white,
    border: `1px solid ${T.slate200}`,
    borderRadius: 12,
    padding: vp.isPhone ? 20 : 32,
    boxShadow: "0 1px 3px rgba(45,47,38,0.06)",
    boxSizing: "border-box",
  };
  const btnPrimary = {
    background: T.blue,
    color: T.white,
    border: "none",
    padding: "12px 24px",
    borderRadius: 8,
    fontSize: 15,
    fontWeight: 600,
    cursor: "pointer",
    boxSizing: "border-box",
  };

  // ── Screens ───────────────────────────────────────────────────

  if (screen === "loading") {
    return (
      <div style={container}>
        <div style={{ ...card, textAlign: "center", padding: 40 }}>
          <div style={{ color: T.slate500 }}>Loading…</div>
        </div>
      </div>
    );
  }

  if (screen === "error") {
    return (
      <div style={container}>
        <div style={card}>
          <div
            style={{
              fontSize: 12,
              fontWeight: 700,
              color: T.red,
              letterSpacing: 1,
              textTransform: "uppercase",
              marginBottom: 12,
            }}
          >
            Unable to load
          </div>
          <div style={{ color: T.slate700, lineHeight: 1.6, fontSize: 15 }}>
            {fatalError || "Something went wrong."}
          </div>
        </div>
      </div>
    );
  }

  if (screen === "welcome") {
    return (
      <div style={container}>
        <div style={card}>
          <div
            style={{
              fontSize: 12,
              fontWeight: 700,
              color: T.blue,
              letterSpacing: 1,
              textTransform: "uppercase",
              marginBottom: 8,
            }}
          >
            Newtworks Assessment
          </div>
          <h1
            style={{
              fontSize: vp.isPhone ? 24 : 28,
              fontWeight: 700,
              margin: "0 0 20px 0",
              color: T.slate900,
              lineHeight: 1.2,
            }}
          >
            Welcome
            {candidate?.first_name ? `, ${candidate.first_name}` : ""}.
          </h1>
          {candidate?.position ? (
            <div
              style={{
                color: T.slate600,
                marginBottom: 20,
                fontSize: 15,
              }}
            >
              Position:{" "}
              <strong style={{ color: T.slate900 }}>{candidate.position}</strong>
            </div>
          ) : null}
          <div
            style={{
              color: T.slate700,
              lineHeight: 1.6,
              marginBottom: 16,
              fontSize: 15,
            }}
          >
            You've been invited to complete a short assessment. It's a series of
            statements you'll respond to on a 1–5 scale, plus a few quick
            problem-solving questions.
          </div>
          <div
            style={{
              color: T.slate700,
              lineHeight: 1.6,
              marginBottom: 16,
              fontSize: 15,
            }}
          >
            This works both ways. It's a chance for me to learn how you
            naturally think and work — and a chance for you to see whether this
            role suits the way you like to work. The best hires I've made have
            felt like the right fit for both sides.
          </div>
          <div
            style={{
              color: T.slate700,
              lineHeight: 1.6,
              marginBottom: 28,
              fontSize: 15,
            }}
          >
            There are no right or wrong answers on the statements — the goal is
            an honest read on how you naturally think and work. Your best guess
            is fine on any question. Plan on 45–60 minutes. You can refresh the
            page and pick up where you left off.
          </div>
          <button style={btnPrimary} onClick={runServe}>
            Begin
          </button>
        </div>
      </div>
    );
  }

  if (screen === "expansion_intro") {
    const remaining = items?.length ?? 0;
    // Stint-aware break-screen copy. The one-size-fits-all "short section"
    // wording was written for the adaptive expansion (stint 3) but also fired
    // before the 158-item stint-2 baseline battery — the 2026-08-05 self-test
    // saw "one more short section … About 158 more questions." Stint 2 is the
    // longest part of the assessment; say so honestly, with a real time
    // estimate (self-test pace: ~6 s per rating statement). Stint 3 keeps the
    // adaptive framing (accurate there). Stint 4 is the SJT.
    const eyebrow =
      stint === 2 ? "Section 2" : stint === 4 ? "Final section" : "Follow-up section";
    const headline =
      stint === 2
        ? "Nice work — the problem-solving section is done."
        : stint === 4
        ? "Last section."
        : "A few follow-up questions.";
    const bodyLead =
      stint === 2
        ? "Next is the longest part of the assessment: a series of quick statements about how you naturally think and work. Rate how well each one describes you and move on — your first instinct is the right speed."
        : stint === 4
        ? "This section is short workplace scenarios. Read each one and pick the response closest to what you would actually do."
        : "Based on how you answered so far, I'd like to ask a few follow-up questions on a couple of areas where a clearer read would help. This is normal — the assessment adds questions when it needs more signal, not because anything is wrong.";
    const bodyCount =
      stint === 2
        ? `${remaining} statements — most people finish this section in about 15–20 minutes.`
        : stint === 4
        ? `${remaining} short scenarios and you're done.`
        : remaining > 0
        ? `About ${remaining} more question${remaining === 1 ? "" : "s"} to go. Same format as before.`
        : "Just a few more questions in the same format as before.";
    return (
      <div style={container}>
        <div style={card}>
          <div
            style={{
              fontSize: 12,
              fontWeight: 700,
              color: T.blue,
              letterSpacing: 1,
              textTransform: "uppercase",
              marginBottom: 8,
            }}
          >
            {eyebrow}
          </div>
          <h1
            style={{
              fontSize: vp.isPhone ? 22 : 26,
              fontWeight: 700,
              margin: "0 0 20px 0",
              color: T.slate900,
              lineHeight: 1.2,
            }}
          >
            {headline}
          </h1>
          <div
            style={{
              color: T.slate700,
              lineHeight: 1.6,
              marginBottom: 16,
              fontSize: 15,
            }}
          >
            {bodyLead}
          </div>
          <div
            style={{
              color: T.slate700,
              lineHeight: 1.6,
              marginBottom: 28,
              fontSize: 15,
            }}
          >
            {bodyCount}
          </div>
          <div
            style={{
              color: T.slate500,
              lineHeight: 1.5,
              marginBottom: 20,
              fontSize: 14,
              fontStyle: "italic",
            }}
          >
            Take a moment. When ready, continue.
          </div>
          <button style={btnPrimary} onClick={() => setScreen("expansion")}>
            Continue
          </button>
        </div>
      </div>
    );
  }

  if (screen === "thanks") {
    return (
      <div style={container}>
        <div style={{ ...card, padding: vp.isPhone ? 24 : 40 }}>
          <div
            style={{
              fontSize: 12,
              fontWeight: 700,
              color: T.blue,
              letterSpacing: 1,
              textTransform: "uppercase",
              marginBottom: 8,
            }}
          >
            Complete
          </div>
          <h1
            style={{
              fontSize: vp.isPhone ? 24 : 28,
              fontWeight: 700,
              margin: "0 0 16px 0",
              color: T.slate900,
              lineHeight: 1.2,
            }}
          >
            All done{candidate?.first_name ? `, ${candidate.first_name}` : ""}.
          </h1>
          <div
            style={{
              color: T.slate700,
              lineHeight: 1.6,
              marginBottom: 16,
              fontSize: 15,
            }}
          >
            Thank you for taking the time. Your responses have been recorded,
            and someone from the team will be in touch shortly.
          </div>
          <div style={{ color: T.slate500, marginTop: 24, fontSize: 13 }}>
            You can close this window.
          </div>
        </div>
      </div>
    );
  }

  // ── Primary / Expansion item render ───────────────────────────
  const item = items[currentIdx];
  if (!item) {
    return (
      <div style={container}>
        <div style={{ ...card, textAlign: "center", padding: 40 }}>
          <div style={{ color: T.slate500 }}>Preparing next question…</div>
        </div>
      </div>
    );
  }

  const batchPct =
    items.length > 0 ? Math.round((currentIdx / items.length) * 100) : 0;
  const overallPct =
    overall.total > 0
      ? Math.round((overall.answered / overall.total) * 100)
      : 0;

  return (
    <div style={container}>
      <div style={card}>
        {/* Progress header */}
        <div style={{ marginBottom: 24 }}>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
              marginBottom: 8,
              fontSize: 12,
              color: T.slate500,
              flexWrap: "wrap",
              gap: 8,
            }}
          >
            <span
              style={{
                fontWeight: 700,
                letterSpacing: 0.5,
                textTransform: "uppercase",
                color: T.blue,
              }}
            >
              {stint === 2
                ? "Section 2"
                : stint === 4
                ? "Final section"
                : stint > 1
                ? "Follow-up section"
                : "Section 1"}
            </span>
            <span>
              {Math.min(currentIdx + 1, items.length)} of {items.length}
            </span>
          </div>
          <div
            style={{
              height: 6,
              background: T.slate100,
              borderRadius: 3,
              overflow: "hidden",
              boxSizing: "border-box",
            }}
          >
            <div
              style={{
                width: `${batchPct}%`,
                height: "100%",
                background: T.blue,
                transition: "width 0.3s ease",
              }}
            />
          </div>
        </div>

        {/* Item text — GMA pattern items render their own instruction text
            inside GmaPatternItem below, since item_text for this item type
            is internal rule-authoring metadata, not candidate-facing copy. */}
        {!isGmaPatternItem(item) && !isGmaNumericalItem(item) ? (
          <div
            style={{
              fontSize: vp.isPhone ? 17 : 19,
              lineHeight: 1.5,
              color: T.slate900,
              marginBottom: 24,
              fontWeight: 500,
            }}
          >
            {formatItemText(item)}
          </div>
        ) : null}

        {/* Save error (inline, non-blocking) */}
        {saveError ? (
          <div
            style={{
              padding: "10px 14px",
              background: T.redLt,
              color: T.red,
              border: `1px solid ${T.red}`,
              borderRadius: 8,
              fontSize: 13,
              marginBottom: 16,
              boxSizing: "border-box",
            }}
          >
            {saveError}
          </div>
        ) : null}

        {/* Response controls */}
        <ResponseControls
          item={item}
          onAnswer={handleAnswer}
          saving={saving}
          vp={vp}
        />

        {/* Autosave hint */}
        <div
          style={{
            marginTop: 20,
            textAlign: "center",
            color: T.slate400,
            fontSize: 12,
          }}
        >
          {saving ? "Saving…" : "Your progress is saved automatically."}
        </div>
      </div>
    </div>
  );
}

function ResponseControls({ item, onAnswer, saving, vp }) {
  // GMA pattern-matching item. choices is an OBJECT ({ grid, options }), not
  // an array of text strings, so this must be checked before the multi-choice
  // Array.isArray branch below — otherwise it silently falls through to the
  // Likert-scale renderer instead of the shape grid.
  if (isGmaPatternItem(item)) {
    return <GmaPatternItem item={item} onAnswer={onAnswer} saving={saving} vp={vp} />;
  }

  // GMA numerical-reasoning item. choices is an OBJECT ({ sequence, options
  // }), not an array -- same reason this must be checked before the
  // Array.isArray multi-choice branch below as the pattern-matching check.
  if (isGmaNumericalItem(item)) {
    return <GmaNumericalItem item={item} onAnswer={onAnswer} saving={saving} vp={vp} />;
  }

  // Multi-choice item (choices is a JSONB array).
  if (Array.isArray(item?.choices) && item.choices.length > 0) {
    const choices = orderChoices(item.choices);
    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        {choices.map((choice, i) => (
          <button
            key={`${item?.id ?? "x"}-${i}`}
            disabled={saving}
            onClick={() => onAnswer({ label: String(choice) })}
            style={{
              padding: "14px 16px",
              background: T.white,
              border: `1px solid ${T.slate200}`,
              borderRadius: 8,
              textAlign: "left",
              fontSize: 15,
              color: T.slate900,
              cursor: saving ? "wait" : "pointer",
              transition: "background 0.15s, border-color 0.15s",
              lineHeight: 1.4,
              boxSizing: "border-box",
            }}
          >
            {String(choice)}
          </button>
        ))}
      </div>
    );
  }

  // Likert scale (default when scale_max is set and choices is null).
  const scaleMax = Number.isFinite(item?.scale_max) ? item.scale_max : 5;
  const labels =
    scaleMax === 5
      ? LIKERT_LABELS
      : Array.from({ length: scaleMax }, (_, i) => ({
          value: i + 1,
          label: String(i + 1),
        }));

  if (vp.isPhone) {
    // Phone: stack Likert options vertically.
    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        {labels.map((opt) => (
          <button
            key={`${item?.id ?? "x"}-${opt.value}`}
            disabled={saving}
            onClick={() => onAnswer({ value: opt.value })}
            style={{
              padding: "14px 16px",
              background: T.white,
              border: `1px solid ${T.slate200}`,
              borderRadius: 8,
              textAlign: "left",
              fontSize: 15,
              color: T.slate900,
              cursor: saving ? "wait" : "pointer",
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
              boxSizing: "border-box",
            }}
          >
            <span>{opt.label}</span>
            <span
              style={{
                color: T.blue,
                fontWeight: 700,
                fontSize: 18,
              }}
            >
              {opt.value}
            </span>
          </button>
        ))}
      </div>
    );
  }

  // Desktop / tablet: horizontal Likert row.
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: `repeat(${labels.length}, 1fr)`,
        gap: 10,
      }}
    >
      {labels.map((opt) => (
        <button
          key={`${item?.id ?? "x"}-${opt.value}`}
          disabled={saving}
          onClick={() => onAnswer({ value: opt.value })}
          style={{
            padding: "18px 8px",
            background: T.white,
            border: `1px solid ${T.slate200}`,
            borderRadius: 8,
            textAlign: "center",
            fontSize: 12,
            color: T.slate700,
            cursor: saving ? "wait" : "pointer",
            display: "flex",
            flexDirection: "column",
            gap: 6,
            alignItems: "center",
            justifyContent: "center",
            minHeight: 96,
            lineHeight: 1.3,
            transition: "background 0.15s, border-color 0.15s",
            boxSizing: "border-box",
          }}
        >
          <span
            style={{
              fontWeight: 700,
              color: T.blue,
              fontSize: 22,
            }}
          >
            {opt.value}
          </span>
          <span>{opt.label}</span>
        </button>
      ))}
    </div>
  );
}
