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

// Anchor labels per response scale, matching each source instrument's own
// documented format (citations live in the ingest migrations):
//   4-pt — General Self-Efficacy Scale truth anchors (Schwarzer & Jerusalem 1995)
//   6-pt — VandeWalle 1997 goal-orientation agreement anchors (no midpoint)
//   7-pt — 7-point agreement anchors (proactive personality / networking /
//          customer orientation)
// Before 2026-08-05 anything that wasn't a 5-point scale fell back to bare
// numbers, so every button rendered its number twice ("1" over "1").
const SCALE_ANCHORS = {
  4: ["Not at all true", "Hardly true", "Moderately true", "Exactly true"],
  6: ["Strongly disagree", "Disagree", "Slightly disagree", "Slightly agree", "Agree", "Strongly agree"],
  7: ["Strongly disagree", "Disagree", "Slightly disagree", "Neutral", "Slightly agree", "Agree", "Strongly agree"],
};

// Familiarity-rating anchors for the vocabulary validity block (fake + real
// words). Condensed from the Over-Claiming Questionnaire's published 7-point
// "never heard of it" -> "know it very well" scale to our 5-point format.
// Paulhus, Harms, Bruce & Lysy 2003, Journal of Personality and Social
// Psychology 84(4) 890-904. Selected via response_format = 'vocab_familiarity',
// independent of scale_max, so it never collides with the agree/disagree
// anchors other scale sizes use. Op-rule "Vocabulary overclaiming check
// converted to Paulhus familiarity-rating format" (2026-08-06).
const VOCAB_FAMILIARITY_ANCHORS = [
  "Never heard of it",
  "Heard of it, but don't know what it means",
  "Have some idea what it means",
  "Know what it means fairly well",
  "Know exactly what it means",
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

// Deterministic string hash (djb2) -> used to seed the shuffle below. Same
// seed string always produces the same hash, so the same candidate viewing
// the same item always sees the same choice order, even across reloads.
function djb2Hash(str) {
  let hash = 5381;
  for (let i = 0; i < str.length; i++) {
    hash = (hash * 33) ^ str.charCodeAt(i);
  }
  return hash >>> 0; // force unsigned 32-bit
}

// Mulberry32 PRNG seeded from a 32-bit integer. Deterministic, fast, good
// enough distribution for shuffling a 4-option list -- not cryptographic.
function mulberry32(seed) {
  let a = seed;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Seeded Fisher-Yates shuffle. seedString should uniquely identify the
// (candidate, item) pair so the same candidate always sees the same order
// for the same item on reload, but different candidates see different
// orders. Not Math.random() -- that would reshuffle on every render/reload.
function seededShuffle(arr, seedString) {
  const out = [...arr];
  const rand = mulberry32(djb2Hash(String(seedString)));
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

// Sort choices so any "None of these" option sits last (VCT convention),
// after first shuffling the remaining choices deterministically per
// candidate+item. This breaks the position-2-is-always-correct display
// leak on scenario (SJT) items -- scoring compares selected TEXT against
// answer_key, so storage order was never the issue, only display order.
// seedKey should be `${candidateId}:${item.id}` (or similar) -- omit it
// (or pass a falsy value) to fall back to unshuffled order, e.g. for any
// caller that doesn't have a stable candidate+item identity yet.
function orderChoices(choices, seedKey) {
  if (!Array.isArray(choices)) return [];
  let out = seedKey ? seededShuffle(choices, seedKey) : [...choices];
  const idx = out.findIndex(
    (c) => typeof c === "string" && c.toLowerCase().includes("none of these")
  );
  if (idx !== -1 && idx !== out.length - 1) {
    const [none] = out.splice(idx, 1);
    out.push(none);
  }
  return out;
}

// Items are shown to the candidate exactly as they are stored. Every statement
// in the bank was rewritten to stand on its own as a complete sentence, so
// nothing is prepended to it. Peter directive 2026-08-07: the old "I " stem was
// still being glued onto the front of 116 active statements even after the
// rewording, which mangled them — it lowercased the first word and produced
// "I getting someone to move usually means …" and "I how well do you know the
// word …" (the vocabulary familiarity items lost their multiple-choice payload
// when they moved to a rating format on 2026-08-06, so they slipped past the
// guard that used to protect real questions from being prefixed).
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
  return item.item_text || "";
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
  // Select-then-commit: the option the candidate tapped but has not yet
  // locked in with the Next button. The flow is one-way by design
  // (2026-08-05 decision): the assessment branches on earlier answers and
  // first-instinct responses are the signal, so there is no back
  // navigation -- the pending-selection step is the mis-tap protection
  // that replaces it.
  const [pending, setPending] = useState(null);
  // Shown briefly when browser back (button or iOS edge-swipe) fires
  // mid-assessment; the history guard below re-arms and keeps the
  // candidate on the page.
  const [backNotice, setBackNotice] = useState(false);

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

  // Browser-back guard. iPhone's left-edge swipe (and the back button)
  // fires a real history navigation; unguarded, it dumps a mid-assessment
  // candidate back out to their email app. Push one sentinel entry on
  // mount and re-arm it on every popstate so back keeps the candidate on
  // this page and shows a short notice instead. Escape is still possible
  // (e.g. rapid double-back) and is safe: every answer is already saved
  // server-side and reopening the link resumes mid-flow. NewtworksApp's
  // own popstate listener re-parses an unchanged URL here, so it no-ops.
  useEffect(() => {
    if (typeof window === "undefined") return undefined;
    window.history.pushState({ nwAssessGuard: true }, "");
    const onPop = () => {
      window.history.pushState({ nwAssessGuard: true }, "");
      setBackNotice(true);
    };
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);

  // Auto-hide the back notice.
  useEffect(() => {
    if (!backNotice) return undefined;
    const t = setTimeout(() => setBackNotice(false), 4000);
    return () => clearTimeout(t);
  }, [backNotice]);

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
    setPending(null);
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
            ? "Connection hiccup. Tap Next again to retry."
            : "Save didn't go through. Tap Next again to retry."
        );
        return;
      }
      // Advance both counters and index. Clear the pending selection
      // synchronously so the next item never paints with a stale highlight.
      setPending(null);
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
            statements you'll respond to on a simple rating scale, plus a few quick
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
            is fine on any question. Each answer locks in when you tap Next —
            you can't go back to a previous question, so check your pick
            before moving on. Plan on about 30 minutes. You can refresh the
            page and pick up where you left off.
          </div>
          <div
            style={{
              color: T.slate700,
              lineHeight: 1.6,
              marginBottom: 28,
              fontSize: 15,
              fontWeight: 600,
            }}
          >
            Answer honestly. This assessment includes built-in checks that
            detect exaggerated or inconsistent answering, and results are
            weighted accordingly. Straightforward answers give you the most
            accurate — and best — result.
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
      stint === 2
        ? "Section 2"
        : stint === 4
        ? "Section 3"
        : stint === 5
        ? "Part 2 — final section"
        : "Follow-up section";
    const headline =
      stint === 2
        ? "Nice work — the problem-solving section is done."
        : stint === 4
        ? "Almost there."
        : stint === 5
        ? "Last part — a few written questions."
        : "A few follow-up questions.";
    const bodyLead =
      stint === 2
        ? "Next is the longest part of the assessment: a series of quick statements about how you naturally think and work. Rate how well each one describes you and move on — your first instinct is the right speed."
        : stint === 4
        ? "This section is short workplace scenarios. Read each one and pick the response closest to what you would actually do."
        : stint === 5
        ? "This part is not timed — take your time and answer in your own words. Quality of thought matters more than speed."
        : "Based on how you answered so far, I'd like to ask a few follow-up questions on a couple of areas where a clearer read would help. This is normal — the assessment adds questions when it needs more signal, not because anything is wrong.";
    const bodyCount =
      stint === 2
        ? `${remaining} statements — most people finish this section in about 15–20 minutes.`
        : stint === 4
        ? `${remaining} short scenarios, then one short written section and you're done.`
        : stint === 5
        ? `${remaining} written questions. No time limit.`
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
          {stint === 2 ? (
            <div
              style={{
                color: T.slate700,
                lineHeight: 1.5,
                marginBottom: 20,
                fontSize: 14,
                fontWeight: 600,
              }}
            >
              Reminder: consistency and exaggeration checks are active
              throughout. Honest answers score best.
            </div>
          ) : null}
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
        {backNotice ? (
          <div
            style={{
              padding: "10px 14px",
              background: T.amberLt,
              color: T.slate900,
              border: `1px solid ${T.amber}`,
              borderRadius: 8,
              fontSize: 13,
              lineHeight: 1.4,
              marginBottom: 16,
              boxSizing: "border-box",
            }}
          >
            You can't go back to a previous question — everything you've
            answered is already saved.
          </div>
        ) : null}
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
                ? "Section 3"
                : stint === 5
                ? "Part 2 — final section"
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
          candidateId={candidateId}
          onAnswer={(p) => {
            if (!saving) setPending(p);
          }}
          selected={pending}
          saving={saving}
          vp={vp}
        />

        {/* Commit gate: tapping an option only selects it; Next locks it
            in and saves. This is the deliberate mis-tap protection for the
            one-way (no back navigation) flow — the candidate can change
            their pick freely until Next. */}
        <button
          disabled={saving || !pending}
          onClick={() => {
            if (pending) handleAnswer(pending);
          }}
          style={{
            ...btnPrimary,
            width: "100%",
            marginTop: 20,
            padding: "14px 24px",
            fontSize: 16,
            opacity: saving || !pending ? 0.45 : 1,
            cursor: saving ? "wait" : pending ? "pointer" : "default",
          }}
        >
          {saving ? "Saving…" : "Next"}
        </button>

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

function FreeTextItem({ item, onAnswer, selected, saving }) {
  // Stint 5 (written screen) items only. Local text state, reset when the
  // item changes -- this component is not remounted between questions (same
  // tree position), so without the reset a second free-text question would
  // open pre-filled with the previous answer.
  const [text, setText] = useState(selected?.label ?? "");
  useEffect(() => {
    setText(selected?.label ?? "");
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item?.id]);

  return (
    <textarea
      value={text}
      disabled={saving}
      onChange={(e) => {
        const v = e.target.value;
        setText(v);
        // Empty/whitespace-only -> clear pending (null) so Next stays
        // disabled, matching the multi-choice/Likert controls behavior of
        // starting with no selection. onAnswer here is the ResponseControls
        // prop, which the parent wires straight to setPending.
        onAnswer(v.trim().length > 0 ? { label: v } : null);
      }}
      placeholder="Type your answer here…"
      rows={6}
      style={{
        width: "100%",
        padding: "14px 16px",
        border: `1px solid ${T.slate200}`,
        borderRadius: 8,
        fontSize: 15,
        color: T.slate900,
        fontFamily: "inherit",
        lineHeight: 1.5,
        resize: "vertical",
        boxSizing: "border-box",
      }}
    />
  );
}

function ResponseControls({ item, candidateId, onAnswer, selected, saving, vp }) {
  // Stint 5 (written screen) free-text items. Checked first -- these carry
  // no choices and no scale_max, so without this check they would silently
  // fall through to the Likert-scale default at the bottom of this function.
  if (item?.response_format === "free_text") {
    return <FreeTextItem item={item} onAnswer={onAnswer} selected={selected} saving={saving} />;
  }

  // GMA pattern-matching item. choices is an OBJECT ({ grid, options }), not
  // an array of text strings, so this must be checked before the multi-choice
  // Array.isArray branch below — otherwise it silently falls through to the
  // Likert-scale renderer instead of the shape grid.
  if (isGmaPatternItem(item)) {
    return <GmaPatternItem item={item} onAnswer={onAnswer} selected={selected} saving={saving} vp={vp} />;
  }

  // GMA numerical-reasoning item. choices is an OBJECT ({ sequence, options
  // }), not an array -- same reason this must be checked before the
  // Array.isArray multi-choice branch below as the pattern-matching check.
  if (isGmaNumericalItem(item)) {
    return <GmaNumericalItem item={item} onAnswer={onAnswer} selected={selected} saving={saving} vp={vp} />;
  }

  // Multi-choice item (choices is a JSONB array).
  if (Array.isArray(item?.choices) && item.choices.length > 0) {
    const choices = orderChoices(
      item.choices,
      candidateId && item?.id ? `${candidateId}:${item.id}` : null
    );
    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        {choices.map((choice, i) => (
          <button
            key={`${item?.id ?? "x"}-${i}`}
            disabled={saving}
            onClick={() => onAnswer({ label: String(choice) })}
            style={{
              padding: "14px 16px",
              background: selected?.label === String(choice) ? T.blueLt : T.white,
              border: `1px solid ${selected?.label === String(choice) ? T.blue : T.slate200}`,
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
  const anchorTexts =
    item?.response_format === "vocab_familiarity"
      ? VOCAB_FAMILIARITY_ANCHORS
      : scaleMax === 5
      ? null
      : SCALE_ANCHORS[scaleMax];
  const labels = anchorTexts
    ? anchorTexts.map((label, i) => ({ value: i + 1, label }))
    : scaleMax === 5
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
              background: selected?.value === opt.value ? T.blueLt : T.white,
              border: `1px solid ${selected?.value === opt.value ? T.blue : T.slate200}`,
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
            background: selected?.value === opt.value ? T.blueLt : T.white,
            border: `1px solid ${selected?.value === opt.value ? T.blue : T.slate200}`,
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
