// supabase/functions/v1-assessment/index.ts
// Newtworks v1 assessment — public candidate endpoint.
// Called from /assess/<candidate_id>/<token> route by CandidateAssessment.jsx.
// Frontend never touches Supabase client on the public route; this fn is the sole gateway.
// HMAC token verified on every call. Service-role client bypasses RLS.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Newtworks v1 sections. Any item outside this set is legacy (CTS-era) and never served.
const V1_SECTIONS = [
  "newtworks_v1_personality",
  "newtworks_v1_impression_mgmt",
  "newtworks_v1_vct",
  "cognitive",
];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const supa = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const { candidate_id, token, action } = body ?? {};
  if (!candidate_id || !token || !action) {
    return json({ error: "missing_required_field" }, 400);
  }

  // Every call: verify HMAC token first.
  const { data: verifyOk, error: verifyErr } = await supa.rpc(
    "verify_v1_assessment_token",
    { p_candidate_id: candidate_id, p_token: token }
  );
  if (verifyErr) return json({ error: "verify_failed", detail: verifyErr.message }, 500);
  if (verifyOk !== true) return json({ error: "invalid_token" }, 403);

  // Load candidate greeting context (agency-scoped).
  const { data: cand, error: candErr } = await supa
    .from("hiring_candidates")
    .select("id, first_name, position")
    .eq("id", candidate_id)
    .eq("agency_id", AGENCY_ID)
    .maybeSingle();
  if (candErr) return json({ error: "candidate_fetch_failed", detail: candErr.message }, 500);
  if (!cand) return json({ error: "candidate_not_found" }, 404);

  switch (action) {
    case "verify":
      return await handleVerify(supa, cand);
    case "serve":
      return await handleServe(supa, cand);
    case "save_response":
      return await handleSave(supa, cand, body);
    case "finalize":
      return await handleFinalize(supa, cand);
    default:
      return json({ error: "unknown_action", action }, 400);
  }
});

// --- Progress helpers ---

async function loadPrimaryProgress(supa: any, candidateId: string) {
  const { data: items, error: iErr } = await supa
    .from("hiregauge_instrument_items")
    .select("id")
    .eq("stint", 1)
    .eq("is_active", true)
    .in("section", V1_SECTIONS);
  if (iErr) throw new Error(`primary_items_fetch: ${iErr.message}`);
  const total = (items || []).length;

  const { data: resp, error: rErr } = await supa
    .from("hiregauge_candidate_responses")
    .select("item_id")
    .eq("candidate_id", candidateId)
    .eq("sitting", 1);
  if (rErr) throw new Error(`primary_responses_fetch: ${rErr.message}`);

  const answeredIds = new Set((resp || []).map((r: any) => r.item_id));
  const answered = (items || []).filter((it: any) => answeredIds.has(it.id)).length;

  return {
    total,
    answered,
    primaryAnswered: total > 0 && answered >= total,
  };
}

// Constrained shuffle for served-item ordering.
//   Step 1 — Fisher-Yates baseline (unbiased random permutation).
//   Step 2 — Walk-and-swap pass enforcing spacing constraints:
//     * min 8-item gap between items sharing hypothesized_trait
//       (personality items on the same trait can't cluster)
//     * min 4-item gap between items sharing cognitive_domain
//       (math items can't cluster together)
//     * min 8-item gap between items sharing item_text
//       (defense-in-depth against future duplicates even after retest deactivation)
// Bounded to 20 passes. If constraints stay infeasible past that (batch too
// small or too many items sharing an attribute), accept the best partial
// ordering and return.
function constrainedShuffle<T extends {
  hypothesized_trait?: string | null;
  cognitive_domain?: string | null;
  item_text?: string | null;
}>(arr: T[]): T[] {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  if (a.length < 2) return a;

  const MIN_GAP_TRAIT = 8;
  const MIN_GAP_DOMAIN = 4;
  const MIN_GAP_TEXT = 8;
  const MAX_LOOKBACK = Math.max(MIN_GAP_TRAIT, MIN_GAP_DOMAIN, MIN_GAP_TEXT);

  const violatesAt = (idx: number, item: T): boolean => {
    const trait = item.hypothesized_trait ?? null;
    const domain = item.cognitive_domain ?? null;
    const text = item.item_text ?? null;
    const back = Math.max(0, idx - MAX_LOOKBACK);
    for (let k = back; k < idx; k++) {
      const other = a[k];
      const gap = idx - k;
      if (trait && (other.hypothesized_trait ?? null) === trait && gap < MIN_GAP_TRAIT) return true;
      if (domain && (other.cognitive_domain ?? null) === domain && gap < MIN_GAP_DOMAIN) return true;
      if (text && (other.item_text ?? null) === text && gap < MIN_GAP_TEXT) return true;
    }
    return false;
  };

  for (let pass = 0; pass < 20; pass++) {
    let violations = 0;
    for (let i = 1; i < a.length; i++) {
      if (!violatesAt(i, a[i])) continue;
      violations++;
      // Look forward for a candidate that fits at i.
      for (let j = i + 1; j < a.length; j++) {
        if (!violatesAt(i, a[j])) {
          [a[i], a[j]] = [a[j], a[i]];
          break;
        }
      }
    }
    if (violations === 0) break;
  }

  return a;
}

// Expansion target — describes a filtered slice of stint=2 items to serve.
// Supports the four trigger actions defined in hiregauge_expansion_triggers:
//   expand_trait_stint_2               — section + trait filter (per-trait borderline)
//   expand_cognitive                   — section filter only (borderline overall cognitive)
//   expand_impression_mgmt_and_nonsense — impression-mgmt section AND vct nonsense subset
//   expand_retest_pairs                — any section, retest_of_item_number NOT NULL
type ExpansionTarget = {
  section: string | null;      // null = any section
  trait: string | null;        // null = any trait
  nonsense_only: boolean;      // filter is_nonsense = true
  retest_only: boolean;        // filter retest_of_item_number NOT NULL
  cap: number | null;          // limit item count, null = all
};

// Reduce trigger rows to a unique set of expansion targets.
// null cap means "all matching items" — null always beats any numeric cap.
async function loadExpansionTargets(supa: any, candidateId: string): Promise<ExpansionTarget[]> {
  const { data, error } = await supa.rpc("compute_newtworks_v1_traits_as_row", {
    p_candidate_id: candidateId,
    p_stint: 1,
    p_sitting: 1,
  });
  if (error) throw new Error(`traits_fetch: ${error.message}`);

  const row = Array.isArray(data) ? data[0] : data;
  const triggers = (row?.expansion_triggers ?? []) as any[];

  const map = new Map<string, ExpansionTarget>();

  const addTarget = (tgt: ExpansionTarget) => {
    const key = `${tgt.section ?? "*"}::${tgt.trait ?? "*"}::${tgt.nonsense_only}::${tgt.retest_only}`;
    const existing = map.get(key);
    if (!existing) {
      map.set(key, tgt);
    } else if (tgt.cap === null) {
      existing.cap = null;
    } else if (existing.cap !== null && tgt.cap > existing.cap) {
      existing.cap = tgt.cap;
    }
  };

  for (const t of triggers) {
    switch (t?.action) {
      case "expand_trait_stint_2":
        if (!t?.expansion_section || !t?.expansion_trait) break;
        addTarget({
          section: t.expansion_section,
          trait: t.expansion_trait,
          nonsense_only: false,
          retest_only: false,
          cap: t.expansion_count ?? null,
        });
        break;

      case "expand_cognitive":
        // Newtworks v1 (2026-07-31): cognitive lives fully in stint 1. All
        // active v1 cognitive items are stint=1 after the pool trim/retag;
        // no stint=2 cognitive pathway exists. Any expand_cognitive trigger
        // row is legacy and ignored here.
        break;

      case "expand_impression_mgmt_and_nonsense":
        // Two-part expansion: impression-management section plus fake-vocab
        // items from the validity check section. Both fire together.
        addTarget({
          section: t.expansion_section || "newtworks_v1_impression_mgmt",
          trait: null,
          nonsense_only: false,
          retest_only: false,
          cap: t.expansion_count ?? null,
        });
        addTarget({
          section: "newtworks_v1_vct",
          trait: null,
          nonsense_only: true,
          retest_only: false,
          cap: null,
        });
        break;

      case "expand_retest_pairs":
        // Retest items span sections; only filter by retest flag.
        // No stint=2 retest content authored yet — serves 0 until content lands.
        addTarget({
          section: null,
          trait: null,
          nonsense_only: false,
          retest_only: true,
          cap: t.expansion_count ?? null,
        });
        break;

      // Unknown action — ignore silently.
    }
  }

  return Array.from(map.values());
}

// --- Action handlers ---

async function handleVerify(supa: any, cand: any) {
  try {
    const prog = await loadPrimaryProgress(supa, cand.id);
    let expansionReady = false;
    if (prog.primaryAnswered) {
      const targets = await loadExpansionTargets(supa, cand.id);
      expansionReady = targets.length > 0;
    }
    return json({
      ok: true,
      candidate: { first_name: cand.first_name, position: cand.position },
      primary_answered: prog.primaryAnswered,
      expansion_ready: expansionReady,
      progress: { answered: prog.answered, total: prog.total },
    });
  } catch (e: any) {
    return json({ error: "verify_action_failed", detail: e.message }, 500);
  }
}

async function handleServe(supa: any, cand: any) {
  try {
    const prog = await loadPrimaryProgress(supa, cand.id);

    // Load answered set (shared between stints since sitting=1 covers both).
    const { data: respRows, error: rErr } = await supa
      .from("hiregauge_candidate_responses")
      .select("item_id")
      .eq("candidate_id", cand.id)
      .eq("sitting", 1);
    if (rErr) return json({ error: "responses_fetch_failed", detail: rErr.message }, 500);
    const answered = new Set((respRows || []).map((r: any) => r.item_id));

    if (!prog.primaryAnswered) {
      // Stint 1 phase: return all unanswered stint=1 items.
      const { data: items, error: iErr } = await supa
        .from("hiregauge_instrument_items")
        .select(
          "id, section, item_number, item_text, choices, scale_max, is_nonsense, hypothesized_trait, cognitive_domain"
        )
        .eq("stint", 1)
        .eq("is_active", true)
        .in("section", V1_SECTIONS)
        .order("section", { ascending: true })
        .order("item_number", { ascending: true });
      if (iErr) return json({ error: "items_fetch_failed", detail: iErr.message }, 500);

      const unanswered = (items || []).filter((it: any) => !answered.has(it.id));
      return json({
        stint: 1,
        done: unanswered.length === 0,
        items: constrainedShuffle(unanswered),
        progress: { answered: prog.answered, total: prog.total },
      });
    }

    // Stint 2 phase: compute triggers → collect targeted stint=2 items.
    const targets = await loadExpansionTargets(supa, cand.id);
    if (targets.length === 0) {
      return json({ stint: 2, done: true, items: [], progress: { answered: 0, total: 0 } });
    }

    const collected: Record<string, any> = {};
    for (const tgt of targets) {
      let q = supa
        .from("hiregauge_instrument_items")
        .select(
          "id, section, item_number, item_text, choices, scale_max, is_nonsense, hypothesized_trait, cognitive_domain"
        )
        .eq("stint", 2)
        .eq("is_active", true);
      if (tgt.section) q = q.eq("section", tgt.section);
      if (tgt.trait) q = q.eq("hypothesized_trait", tgt.trait);
      if (tgt.nonsense_only) q = q.eq("is_nonsense", true);
      if (tgt.retest_only) q = q.not("retest_of_item_number", "is", null);
      q = q.order("item_number", { ascending: true });
      if (tgt.cap != null) q = q.limit(tgt.cap);
      const { data: batch, error: bErr } = await q;
      if (bErr) return json({ error: "expansion_fetch_failed", detail: bErr.message }, 500);
      for (const it of batch || []) collected[it.id] = it;
    }

    const stint2All = Object.values(collected).sort((a: any, b: any) =>
      a.section === b.section ? a.item_number - b.item_number : a.section.localeCompare(b.section)
    );
    const unanswered = stint2All.filter((it: any) => !answered.has(it.id));

    return json({
      stint: 2,
      done: unanswered.length === 0,
      items: constrainedShuffle(unanswered),
      progress: {
        answered: stint2All.length - unanswered.length,
        total: stint2All.length,
      },
    });
  } catch (e: any) {
    return json({ error: "serve_action_failed", detail: e.message }, 500);
  }
}

async function handleSave(supa: any, cand: any, body: any) {
  const { item_id, response_value, response_label, served_at } = body ?? {};
  if (!item_id) return json({ error: "missing_item_id" }, 400);
  if (response_value == null && response_label == null) {
    return json({ error: "missing_response" }, 400);
  }

  // Defense-in-depth: confirm item is a live v1 item.
  const { data: item, error: iErr } = await supa
    .from("hiregauge_instrument_items")
    .select("id, section, stint, is_active, answer_key")
    .eq("id", item_id)
    .maybeSingle();
  if (iErr) return json({ error: "item_fetch_failed", detail: iErr.message }, 500);
  if (!item) return json({ error: "item_not_found" }, 404);
  if (!V1_SECTIONS.includes(item.section) || item.stint == null || !item.is_active) {
    return json({ error: "item_not_v1_active" }, 400);
  }

  // Auto-score answer_key items (VCT / cognitive) when a label is provided.
  let is_correct: boolean | null = null;
  if (item.answer_key != null && response_label != null) {
    is_correct = String(response_label).trim() === String(item.answer_key).trim();
  }

  // Timing capture (Step A / Item 4). served_at was emitted by handleServe when
  // it handed this item to the candidate; frontend echoes it back on save.
  // answered_at is server-clock at write time. Parse defensively — bad or
  // missing served_at drops through to NULL so the row still writes.
  const answered_at_iso = new Date().toISOString();
  let served_at_iso: string | null = null;
  if (typeof served_at === "string" && served_at.length > 0) {
    const parsed = new Date(served_at);
    if (!Number.isNaN(parsed.getTime())) {
      served_at_iso = parsed.toISOString();
    }
  }

  const { error: upErr } = await supa
    .from("hiregauge_candidate_responses")
    .upsert(
      {
        agency_id: AGENCY_ID,
        candidate_id: cand.id,
        item_id,
        response_value: response_value ?? null,
        response_label: response_label ?? null,
        is_correct,
        sitting: 1,
        served_at: served_at_iso,
        answered_at: answered_at_iso,
      },
      { onConflict: "candidate_id,item_id" }
    );
  if (upErr) return json({ error: "save_failed", detail: upErr.message }, 500);

  // Stamp hiring_candidates.assessment_started_at on the first successful save
  // for this candidate. Set-once semantics: the .is("assessment_started_at", null)
  // clause makes the UPDATE a no-op on subsequent saves without needing a
  // separate SELECT-then-UPDATE round-trip. Failure here never blocks the save
  // response — timing capture is a diagnostic layer, not a correctness gate.
  try {
    await supa
      .from("hiring_candidates")
      .update({ assessment_started_at: answered_at_iso })
      .eq("id", cand.id)
      .eq("agency_id", AGENCY_ID)
      .is("assessment_started_at", null);
  } catch (_e) {
    // Silent — see note above.
  }

  return json({ ok: true });
}

async function handleFinalize(supa: any, cand: any) {
  // Peter directive 2026-07-29 (path a): write merged v1 trait output into the
  // flat hiring_candidates columns so existing consumers (v_hiring_candidates,
  // 7 assessment_role_fit_<role> fns, verdict_overall, CandidateDetail Results
  // matrix) render v1 candidates without a rewire. Coexistence-safe with CTS
  // PDF ingest — each candidate is populated by exactly one source. Path (b)
  // cleanup (rewire consumers to call compute_newtworks_v1_traits_as_row
  // directly) tracked in open_questions and revisited once CTS retires
  // (OQ 2317444c).
  try {
    // Completion gate (Peter directive 2026-07-29, soundness review): block
    // finalize when the assessment isn't actually done. Prevents a client-side
    // early "submit" from producing an incomplete profile.
    //   - Stint 1 must be fully answered.
    //   - If any expansion trigger fired, every expected stint=2 item must be
    //     answered too. Response 409 tells the client to keep serving.
    const prog = await loadPrimaryProgress(supa, cand.id);
    if (!prog.primaryAnswered) {
      return json(
        {
          error: "assessment_incomplete",
          stage: "stint_1",
          answered: prog.answered,
          total: prog.total,
        },
        409
      );
    }

    const expTargets = await loadExpansionTargets(supa, cand.id);
    if (expTargets.length > 0) {
      // Build the set of item ids that stint 2 should have served for this
      // candidate. Mirrors handleServe's stint 2 fetch logic exactly.
      const expected: Record<string, boolean> = {};
      for (const tgt of expTargets) {
        let q = supa
          .from("hiregauge_instrument_items")
          .select("id")
          .eq("stint", 2)
          .eq("is_active", true);
        if (tgt.section) q = q.eq("section", tgt.section);
        if (tgt.trait) q = q.eq("hypothesized_trait", tgt.trait);
        if (tgt.nonsense_only) q = q.eq("is_nonsense", true);
        if (tgt.retest_only) q = q.not("retest_of_item_number", "is", null);
        q = q.order("item_number", { ascending: true });
        if (tgt.cap != null) q = q.limit(tgt.cap);
        const { data: batch, error: bErr } = await q;
        if (bErr) {
          return json(
            { error: "expansion_gate_fetch_failed", detail: bErr.message },
            500
          );
        }
        for (const it of batch || []) expected[it.id] = true;
      }
      const expectedIds = Object.keys(expected);
      if (expectedIds.length > 0) {
        const { data: expResp } = await supa
          .from("hiregauge_candidate_responses")
          .select("item_id")
          .eq("candidate_id", cand.id)
          .eq("sitting", 1)
          .in("item_id", expectedIds);
        const answeredSet = new Set(
          (expResp || []).map((r: any) => r.item_id)
        );
        const missing = expectedIds.length - answeredSet.size;
        if (missing > 0) {
          return json(
            {
              error: "assessment_incomplete",
              stage: "expansion",
              answered: expectedIds.length - missing,
              total: expectedIds.length,
            },
            409
          );
        }
      }
    }

    // Merged read (p_stint = NULL) scores stint 1 + stint 2 items together on
    // sitting=1. That merged score is what lands in the flat columns.
    const { data: pm, error: pmErr } = await supa.rpc(
      "compute_newtworks_v1_traits_as_row",
      { p_candidate_id: cand.id, p_stint: null, p_sitting: 1 }
    );
    if (pmErr) {
      return json({ error: "merged_compute_failed", detail: pmErr.message }, 500);
    }
    const rm = Array.isArray(pm) ? pm[0] : pm;

    // Per-stint reads kept for the response payload / observability.
    const { data: p1 } = await supa.rpc("compute_newtworks_v1_traits_as_row", {
      p_candidate_id: cand.id,
      p_stint: 1,
      p_sitting: 1,
    });
    const { data: p2 } = await supa.rpc("compute_newtworks_v1_traits_as_row", {
      p_candidate_id: cand.id,
      p_stint: 2,
      p_sitting: 1,
    });
    const r1 = Array.isArray(p1) ? p1[0] : p1;
    const r2 = Array.isArray(p2) ? p2[0] : p2;

    // Guard: only write flat columns when we actually have something scored.
    // Blocks a premature finalize from wiping existing CTS-source data with
    // NULLs. Requires both n_items_scored > 0 and overall_score not null.
    let updated = false;
    let update_skip_reason: string | null = null;
    if ((rm?.n_items_scored ?? 0) > 0 && rm?.overall_score != null) {
      // Timing (Step A / Item 4): stamp assessment_completed_at at the same
      // moment the flat trait columns land. Only fires when the guard above
      // decided the row is real and complete enough to write — no premature
      // completion stamps.
      const finalized_at_iso = new Date().toISOString();
      const { error: upErr } = await supa
        .from("hiring_candidates")
        .update({
          assertiveness:           rm.assertiveness       ?? null,
          independent_spirit:      rm.independent_spirit  ?? null,
          compassion:              rm.compassion          ?? null,
          belief_in_others:        rm.belief_in_others    ?? null,
          optimism:                rm.optimism            ?? null,
          analytical:              rm.analytical          ?? null,
          deadline_motivation:     rm.deadline_motivation ?? null,
          self_promotion:          rm.self_promotion      ?? null,
          recognition_drive:       rm.recognition_drive   ?? null,
          overall_score:           rm.overall_score       ?? null,
          assessment_date:         finalized_at_iso.slice(0, 10),
          assessment_completed_at: finalized_at_iso,
          assessment_source:       "v1",
        })
        .eq("id", cand.id)
        .eq("agency_id", AGENCY_ID);
      if (upErr) {
        return json({ error: "flat_update_failed", detail: upErr.message }, 500);
      }
      updated = true;

      // Step B / Item 3: populate per-subtest LSS flat columns from responses.
      // Non-blocking — LSS surfacing is a diagnostic layer; a helper failure
      // must not block the finalize response the candidate flow depends on.
      try {
        await supa.rpc("apply_newtworks_v1_lss_to_candidate", {
          p_candidate_id: cand.id,
        });
      } catch (_lssErr) {
        // Silent — see note above.
      }
    } else {
      update_skip_reason =
        (rm?.n_items_scored ?? 0) === 0 ? "no_items_scored" : "overall_score_null";
    }

    // Status flip on completion (Peter directive 2026-07-29, OQ 26e829ec).
    // Only advances 'applied' -> 'assessed'. Never touches declined/hired/former
    // or already-assessed rows. Failure never blocks the finalize response.
    let status_flipped = false;
    if (updated) {
      try {
        const { data: flipped, error: flipErr } = await supa
          .from("hiring_candidates")
          .update({ status: "assessed" })
          .eq("id", cand.id)
          .eq("agency_id", AGENCY_ID)
          .eq("status", "applied")
          .select("id");
        if (!flipErr && Array.isArray(flipped) && flipped.length > 0) {
          status_flipped = true;
        }
      } catch (_e) {
        // Silent — status flip is a convenience, not a blocker.
      }
    }

    // Completion notification (Peter directive 2026-07-29, OQ 78fc2c06).
    // Fires exactly once per candidate: alert row + Telegram DM to Peter via
    // @paper_newt_bot. Dedup key = alerts row with (alert_type, related_id).
    // Failures here never fail the finalize response — DM/alert are downstream
    // of the score write, which is what the candidate's flow depends on.
    let notification_fired = false;
    let notification_skip_reason: string | null = null;
    if (updated) {
      try {
        const { data: existing } = await supa
          .from("alerts")
          .select("id")
          .eq("agency_id", AGENCY_ID)
          .eq("alert_type", "v1_assessment_complete")
          .eq("related_id", cand.id)
          .limit(1)
          .maybeSingle();

        if (existing) {
          notification_skip_reason = "already_notified";
        } else {
          // Pull last_name + position for the notification body.
          const { data: fullCand } = await supa
            .from("hiring_candidates")
            .select("first_name, last_name, position")
            .eq("id", cand.id)
            .maybeSingle();
          const candName =
            [fullCand?.first_name, fullCand?.last_name].filter(Boolean).join(" ") ||
            "Unknown candidate";
          const position = fullCand?.position || "unspecified role";

          // Top 3 expansion triggers, if any.
          const triggers = ((rm?.expansion_triggers ?? []) as any[])
            .filter((t) => t?.action === "expand_trait_stint_2");
          const triggerLines = triggers
            .slice(0, 3)
            .map((t) => `${t.expansion_section}/${t.expansion_trait}`)
            .join(", ");
          const triggerSuffix = triggerLines
            ? triggers.length > 3
              ? ` (expansions: ${triggerLines}, +${triggers.length - 3} more)`
              : ` (expansions: ${triggerLines})`
            : "";

          const link = `https://newtworks.vercel.app/?module=team&candidate=${cand.id}`;
          const title = `Assessment complete: ${candName}`;
          const message =
            `${candName} finished the Newtworks v1 assessment for ` +
            `${position}. Overall score ${rm.overall_score} / 100 across ` +
            `${rm.n_items_scored} items${triggerSuffix}. View: ${link}`;

          const { error: alertErr } = await supa.from("alerts").insert({
            agency_id: AGENCY_ID,
            alert_type: "v1_assessment_complete",
            severity: "info",
            title,
            message,
            module_reference: "hiring",
            related_id: cand.id,
            is_read: false,
            is_resolved: false,
          });
          if (alertErr) throw new Error(`alert_insert_failed: ${alertErr.message}`);

          // Owner chat_id lookup — narrow query. is_admin_backoffice guard
          // matches the team-table exclusion pattern.
          const { data: owner } = await supa
            .from("team")
            .select("telegram_user_id")
            .eq("agency_id", AGENCY_ID)
            .eq("role_level", "Owner")
            .eq("is_admin_backoffice", false)
            .is("archived_at", null)
            .maybeSingle();
          const peterChatId = owner?.telegram_user_id ?? null;

          if (peterChatId) {
            const dmText =
              `\u{1F4DD} Assessment complete: ${candName} (${position})\n` +
              `Overall: ${rm.overall_score} / 100 \u00B7 ${rm.n_items_scored} items${triggerSuffix}\n` +
              `${link}`;
            const { error: dmErr } = await supa.rpc("paper_newt_send_message", {
              p_chat_id: peterChatId,
              p_text: dmText,
            });
            if (dmErr) {
              notification_skip_reason = `dm_failed: ${dmErr.message}`;
            } else {
              notification_fired = true;
            }
          } else {
            notification_skip_reason = "owner_chat_id_missing";
          }
        }
      } catch (notifyErr: any) {
        notification_skip_reason = `notify_error: ${notifyErr?.message ?? "unknown"}`;
      }
    }

    return json({
      ok: true,
      done: true,
      updated,
      update_skip_reason,
      status_flipped,
      notification_fired,
      notification_skip_reason,
      merged: {
        n_items_scored: rm?.n_items_scored ?? 0,
        overall_score: rm?.overall_score ?? null,
      },
      stint_1: {
        n_items_scored: r1?.n_items_scored ?? 0,
        overall_score: r1?.overall_score ?? null,
      },
      stint_2: {
        n_items_scored: r2?.n_items_scored ?? 0,
        overall_score: r2?.overall_score ?? null,
      },
    });
  } catch (e: any) {
    return json({ error: "finalize_action_failed", detail: e.message }, 500);
  }
}
