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

// Reduce trigger rows to a unique set of (section, trait) targets with combined cap.
// null cap means "all matching items" — null always beats any numeric cap.
async function loadExpansionTargets(supa: any, candidateId: string) {
  const { data, error } = await supa.rpc("compute_newtworks_v1_traits_as_row", {
    p_candidate_id: candidateId,
    p_stint: 1,
    p_sitting: 1,
  });
  if (error) throw new Error(`traits_fetch: ${error.message}`);

  const row = Array.isArray(data) ? data[0] : data;
  const triggers = (row?.expansion_triggers ?? []) as any[];

  const map = new Map<string, { section: string; trait: string; cap: number | null }>();
  for (const t of triggers) {
    if (t?.action !== "expand_trait_stint_2") continue;
    if (!t?.expansion_section || !t?.expansion_trait) continue;
    const k = `${t.expansion_section}::${t.expansion_trait}`;
    const cap = t.expansion_count ?? null;
    const existing = map.get(k);
    if (!existing) {
      map.set(k, { section: t.expansion_section, trait: t.expansion_trait, cap });
    } else if (cap === null) {
      existing.cap = null; // "all" wins over any numeric cap
    } else if (existing.cap !== null && cap > existing.cap) {
      existing.cap = cap;
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
          "id, section, item_number, item_text, choices, scale_max, is_nonsense, hypothesized_trait"
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
        items: unanswered,
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
          "id, section, item_number, item_text, choices, scale_max, is_nonsense, hypothesized_trait"
        )
        .eq("stint", 2)
        .eq("is_active", true)
        .eq("section", tgt.section)
        .eq("hypothesized_trait", tgt.trait)
        .order("item_number", { ascending: true });
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
      items: unanswered,
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
  const { item_id, response_value, response_label } = body ?? {};
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
      },
      { onConflict: "candidate_id,item_id" }
    );
  if (upErr) return json({ error: "save_failed", detail: upErr.message }, 500);

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
      const { error: upErr } = await supa
        .from("hiring_candidates")
        .update({
          assertiveness:       rm.assertiveness       ?? null,
          independent_spirit:  rm.independent_spirit  ?? null,
          compassion:          rm.compassion          ?? null,
          belief_in_others:    rm.belief_in_others    ?? null,
          optimism:            rm.optimism            ?? null,
          analytical:          rm.analytical          ?? null,
          deadline_motivation: rm.deadline_motivation ?? null,
          self_promotion:      rm.self_promotion      ?? null,
          recognition_drive:   rm.recognition_drive   ?? null,
          overall_score:       rm.overall_score       ?? null,
          assessment_date:     new Date().toISOString().slice(0, 10),
        })
        .eq("id", cand.id)
        .eq("agency_id", AGENCY_ID);
      if (upErr) {
        return json({ error: "flat_update_failed", detail: upErr.message }, 500);
      }
      updated = true;
    } else {
      update_skip_reason =
        (rm?.n_items_scored ?? 0) === 0 ? "no_items_scored" : "overall_score_null";
    }

    return json({
      ok: true,
      done: true,
      updated,
      update_skip_reason,
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
