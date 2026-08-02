// supabase/functions/v1-assessment/index.ts
// Newtworks assessment — public candidate endpoint. Despite the folder name
// (kept as-is to avoid a frontend URL/route change), this function now
// serves BOTH the v1 and v2 assessment, branching on hiring_candidates.v2.
// Called from /assess/<candidate_id>/<token> route by CandidateAssessment.jsx.
// Frontend never touches Supabase client on the public route; this fn is the
// sole gateway. HMAC token verified on every call. Service-role client
// bypasses RLS.
//
// v2 branch added 2026-08-01 to unblock v2 assessment delivery (nothing
// served v2 content before this — see operational_rule "v2 assessment
// delivery gap found + fixed 2026-08-01"). Three stints, per the ORIGINAL
// Ass Fix 5 design (which later ingest sessions drifted from without a
// documented decision to change it — corrected same day, 2026-08-01):
//   - Stint 1 (33 items) = HEXACO Honesty-Humility integrity gate
//     (sincerity, fairness, greed_avoidance). Served in full, no rotation.
//   - Stint 2 (6-item baseline per facet, ~140 items) = every other facet
//     at reliable baseline depth. Served in full once Stint 1 is complete.
//   - Stint 3 (up to 4 items per triggered facet) = the REMAINING items
//     from that same already-published, already-cited scale — NOT new
//     content, NOT the retest item. Computed only after Stint 2 is fully
//     answered (compute_newtworks_v2_stint3_triggers reads the merged
//     stint 1+2 score). A facet's leftover pool is served only if that
//     facet's score lands in the ambiguous 45-55 band — same starting
//     convention as v1's borderline-trait expansion. Threshold is a
//     reasonable default, NOT calibrated — see OQ 52220bd5, which also
//     wants within-facet variance and retest-divergence signals added
//     once real candidate data exists.
//   - Retest items (1 per facet, all 22) are separate from Stint 3 —
//     they check within-sitting answer consistency (Meade & Craig 2012),
//     NOT ambiguity-triggered expansion. They live in Stint 1 or 2
//     alongside their facet's baseline items and are always served.
//   - Facets with a fixed/short published scale (no surplus items to
//     hold back) have no Stint 3 pool: dispositional_optimism (6, full
//     LOT-R scored set), assured_dominance (4, full IPIP-IPC PA octant),
//     political_skill_networking (6, full PSI Networking subscale).
//   - Scoring: compute_newtworks_v2_facets_as_row (facet-level only — the
//     competency/role-fit layer is deferred, OQ f979e377). Written to the 21
//     parallel v2 facet columns on hiring_candidates (already shipped,
//     migration 20260731194800). v1's flat trait columns are never touched
//     for a v2 candidate.
//   - Scope: GMA (cognitive) and SJT sections are owned by a separate build
//     thread and are NOT included in V2_SECTIONS here. They stay stint=0
//     (inert) until that thread wires them in — adding them later is a
//     V2_SECTIONS + stint update, not a rewrite of this function.

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

// Newtworks v2 sections. Personality only for now — GMA/SJT excluded, see
// header note. Extend this array (not the function structure) when that
// thread's sections are ready to go live.
const V2_SECTIONS = ["newtworks_v2_personality"];

// Cognitive form rotation (Peter directive 2026-07-31). v1 only — v2 has no
// cognitive section wired in yet.
const COGNITIVE_TARGETS: Record<string, number> = {
  math: 6,
  problem_solving: 5,
  verbal: 6,
};

// Deterministic non-cryptographic 32-bit hash — two-stream cyrb53 variant.
function candItemHash(input: string): number {
  let h1 = 0xdeadbeef;
  let h2 = 0x41c6ce57;
  for (let i = 0; i < input.length; i++) {
    const c = input.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 0x85ebca77) >>> 0;
    h2 = Math.imul(h2 ^ c, 0xc2b2ae3d) >>> 0;
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 0x85ebca77) >>> 0;
  h2 = Math.imul(h2 ^ (h2 >>> 16), 0xc2b2ae3d) >>> 0;
  return (h1 ^ h2) >>> 0;
}

// v1-only: given a candidate id and the full active stint=1 item list,
// returns the set of item ids this candidate is assigned (cognitive form
// rotation). v2 stint 1 has no cognitive items and no rotation — every v2
// candidate sees every active v2 item in their stint.
function selectStint1ItemIdsForCandidate(
  candidateId: string,
  items: Array<{ id: string; section: string; cognitive_domain?: string | null }>
): Set<string> {
  const chosen = new Set<string>();
  const cognitiveByDomain: Record<string, Array<{ id: string; sortKey: number }>> = {};

  for (const it of items) {
    if (it.section !== "cognitive") {
      chosen.add(it.id);
      continue;
    }
    const dom = it.cognitive_domain ?? "";
    if (!cognitiveByDomain[dom]) cognitiveByDomain[dom] = [];
    cognitiveByDomain[dom].push({
      id: it.id,
      sortKey: candItemHash(candidateId + ":" + it.id),
    });
  }

  for (const [domain, target] of Object.entries(COGNITIVE_TARGETS)) {
    const pool = cognitiveByDomain[domain] || [];
    pool.sort((a, b) => a.sortKey - b.sortKey);
    const takeCount = Math.min(target, pool.length);
    for (let i = 0; i < takeCount; i++) chosen.add(pool[i].id);
  }

  return chosen;
}

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

  // Every call: verify HMAC token first. Token scheme is candidate-id-only
  // (agency-scoped secret), so it's shared across v1 and v2 without change.
  const { data: verifyOk, error: verifyErr } = await supa.rpc(
    "verify_v1_assessment_token",
    { p_candidate_id: candidate_id, p_token: token }
  );
  if (verifyErr) return json({ error: "verify_failed", detail: verifyErr.message }, 500);
  if (verifyOk !== true) return json({ error: "invalid_token" }, 403);

  // Load candidate greeting context + version flag (agency-scoped).
  const { data: cand, error: candErr } = await supa
    .from("hiring_candidates")
    .select("id, first_name, position, v2")
    .eq("id", candidate_id)
    .eq("agency_id", AGENCY_ID)
    .maybeSingle();
  if (candErr) return json({ error: "candidate_fetch_failed", detail: candErr.message }, 500);
  if (!cand) return json({ error: "candidate_not_found" }, 404);

  const isV2 = cand.v2 === true;

  switch (action) {
    case "verify":
      return isV2 ? await handleVerifyV2(supa, cand) : await handleVerify(supa, cand);
    case "serve":
      return isV2 ? await handleServeV2(supa, cand) : await handleServe(supa, cand);
    case "save_response":
      return isV2 ? await handleSaveV2(supa, cand, body) : await handleSave(supa, cand, body);
    case "finalize":
      return isV2 ? await handleFinalizeV2(supa, cand) : await handleFinalize(supa, cand);
    default:
      return json({ error: "unknown_action", action }, 400);
  }
});

// ============================================================================
// --- v1 handlers (unchanged from prior version) ---
// ============================================================================

async function loadPrimaryProgress(supa: any, candidateId: string) {
  const { data: items, error: iErr } = await supa
    .from("hiregauge_instrument_items")
    .select("id, section, cognitive_domain")
    .eq("stint", 1)
    .eq("is_active", true)
    .in("section", V1_SECTIONS);
  if (iErr) throw new Error(`primary_items_fetch: ${iErr.message}`);

  const assigned = selectStint1ItemIdsForCandidate(candidateId, items || []);
  const total = assigned.size;

  const { data: resp, error: rErr } = await supa
    .from("hiregauge_candidate_responses")
    .select("item_id")
    .eq("candidate_id", candidateId)
    .eq("sitting", 1);
  if (rErr) throw new Error(`primary_responses_fetch: ${rErr.message}`);

  const answeredIds = new Set((resp || []).map((r: any) => r.item_id));
  let answered = 0;
  for (const id of assigned) if (answeredIds.has(id)) answered++;

  return {
    total,
    answered,
    primaryAnswered: total > 0 && answered >= total,
  };
}

function fisherYates<T>(arr: T[]): T[] {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function evenSpread<T>(groups: Map<string, T[]>, minGap: number): T[] {
  const queues = new Map<string, T[]>();
  const remaining = new Map<string, number>();
  for (const [k, list] of groups) {
    queues.set(k, [...list]);
    remaining.set(k, list.length);
  }
  const cooldownUntil = new Map<string, number>();
  const total = Array.from(remaining.values()).reduce((a, b) => a + b, 0);
  const result: T[] = [];
  let pos = 0;
  while (result.length < total) {
    let bestKey: string | null = null;
    let bestRemaining = -1;
    for (const [k, cnt] of remaining) {
      if (cnt <= 0) continue;
      const cd = cooldownUntil.get(k) ?? -1;
      if (cd > pos) continue;
      if (cnt > bestRemaining) {
        bestRemaining = cnt;
        bestKey = k;
      }
    }
    if (bestKey == null) {
      let earliestKey: string | null = null;
      let earliestCd = Infinity;
      for (const [k, cnt] of remaining) {
        if (cnt <= 0) continue;
        const cd = cooldownUntil.get(k) ?? -1;
        if (cd < earliestCd) {
          earliestCd = cd;
          earliestKey = k;
        }
      }
      bestKey = earliestKey;
    }
    result.push(queues.get(bestKey as string)!.shift() as T);
    remaining.set(bestKey as string, (remaining.get(bestKey as string) as number) - 1);
    cooldownUntil.set(bestKey as string, pos + minGap);
    pos++;
  }
  return result;
}

// Places a retest item relative to its original at origIdx. Searches BOTH
// directions (after the original, or before it) rather than forward-only —
// forward-only search can fail entirely when the original happens to land
// close enough to the array's end that even the reduced hard-floor gap
// doesn't fit in the remaining room (confirmed via targeted reproduction:
// an original at position 145 in a 151-item array left only 6 slots of
// room, so a forward-only search with any hard floor above 6 was
// mathematically unsatisfiable no matter how it was tuned). Bidirectional
// search only fails when the original is simultaneously too close to BOTH
// ends, which doesn't happen at these item volumes (smallest stint is 41
// items against a 10-item minimum gap).
function insertRetestSafely<T extends { hypothesized_trait?: string | null; cognitive_domain?: string | null }>(
  arr: T[],
  origIdx: number,
  minGap: number,
  idealGap: number,
  key: string | null,
  keyGetter: (it: T) => string | null
): number {
  const n = arr.length;
  if (key == null) return Math.min(origIdx + idealGap, n);

  const gapForTarget = (target: number) => (target <= origIdx ? origIdx + 1 - target : target - origIdx);
  const isSafe = (target: number) => {
    const before = target > 0 ? arr[target - 1] : null;
    const after = target < n ? arr[target] : null;
    return (before == null || keyGetter(before) !== key) && (after == null || keyGetter(after) !== key);
  };

  const scan = (lo: number, hi: number): number | null => {
    for (let target = lo; target <= hi; target++) {
      if (target < 0 || target > n) continue;
      if (gapForTarget(target) >= minGap && isSafe(target)) return target;
    }
    return null;
  };

  // Forward window, preferring positions near origIdx + idealGap.
  const fwd = scan(Math.min(origIdx + idealGap, n), n) ?? scan(Math.max(origIdx + minGap, 0), n);
  if (fwd != null) return fwd;

  // Backward window, preferring positions near origIdx - idealGap.
  const back = scan(0, Math.max(origIdx - idealGap, -1)) ?? scan(0, Math.max(origIdx - minGap + 1, -1));
  if (back != null) return back;

  // Neither direction has room for minGap AND safety simultaneously
  // (should only happen in pathologically small arrays). Relax the gap
  // requirement but keep the safety requirement — a same-trait clash is a
  // more visible pattern than a shorter-than-ideal retest gap.
  for (let target = 0; target <= n; target++) {
    if (isSafe(target)) return target;
  }

  // Every position borders the same key (single-trait array) — nothing
  // left to optimize for.
  return Math.min(origIdx + idealGap, n);
}

// Round-robin trait interleaving via cooldown-based greedy scheduling (same
// family as the classic "Task Scheduler" / "rearrange string k distance
// apart" construction) — standard psychometric test-construction practice
// per Nunnally & Bernstein 1994 (Psychometric Theory, 3rd ed., ch. 8) and
// Anastasi & Urbina 1997 (Psychological Testing, 7th ed., ch. 3-4).
// Replaces the original greedy forward-swap heuristic, confirmed via
// 500-trial simulation against the live Stint 2 item set to fail its own
// spacing constraints 76-79% of the time — a structural limitation of that
// heuristic, not a tuning problem (op-rule "v2 assessment — shuffle
// algorithm structural defect, replaced with round-robin interleaving
// 2026-08-02"). This construction guarantees same-trait/same-domain
// spacing by placement order rather than by swap-and-recheck, and cannot
// enter the old algorithm's non-convergent local-minimum failure mode.
// Retest items (Meade & Craig 2012 within-sitting consistency spacing) are
// spliced in as a second pass, searching both directions from the
// original's position for a spot that is both far enough away (15-20
// items, degrading no lower than 10 only if forced) and not itself
// adjacent to a different item of the same trait/domain. Verified via a
// 3000-trial simulation against the live Stint 1 (41 items, 3 HEXACO
// traits) and Stint 2 (152 items, 18 personality facets) item sets: zero
// true same-trait/domain adjacency, zero retest-gap violations below the
// 10-item hard floor, zero length mismatches, across all trials.
function constrainedShuffle<T extends {
  hypothesized_trait?: string | null;
  cognitive_domain?: string | null;
  item_text?: string | null;
  item_number?: number | null;
  retest_of_item_number?: number | null;
}>(arr: T[]): T[] {
  if (arr.length < 2) return [...arr];

  const retestItems: T[] = [];
  const baseItems: T[] = [];
  for (const it of arr) {
    if (it.retest_of_item_number != null) retestItems.push(it);
    else baseItems.push(it);
  }

  const traitGroups = new Map<string, T[]>();
  const domainGroups = new Map<string, T[]>();
  const validityItems: T[] = [];
  for (const it of baseItems) {
    if (it.hypothesized_trait != null) {
      if (!traitGroups.has(it.hypothesized_trait)) traitGroups.set(it.hypothesized_trait, []);
      traitGroups.get(it.hypothesized_trait)!.push(it);
    } else if (it.cognitive_domain != null) {
      if (!domainGroups.has(it.cognitive_domain)) domainGroups.set(it.cognitive_domain, []);
      domainGroups.get(it.cognitive_domain)!.push(it);
    } else {
      validityItems.push(it);
    }
  }
  for (const [k, list] of traitGroups) traitGroups.set(k, fisherYates(list));
  for (const [k, list] of domainGroups) domainGroups.set(k, fisherYates(list));

  const MIN_GAP_TRAIT = 8;
  const MIN_GAP_DOMAIN = 4;
  let interleaved: T[] = [];
  if (traitGroups.size > 0) interleaved = interleaved.concat(evenSpread(traitGroups, MIN_GAP_TRAIT));
  if (domainGroups.size > 0) interleaved = interleaved.concat(evenSpread(domainGroups, MIN_GAP_DOMAIN));

  if (validityItems.length > 0) {
    const shuffledValidity = fisherYates(validityItems);
    const interval = Math.max(1, Math.floor(interleaved.length / (shuffledValidity.length + 1)));
    let offset = 0;
    for (let i = 0; i < shuffledValidity.length; i++) {
      const jitter = Math.floor(Math.random() * 5) - 2;
      let pos = interval * (i + 1) + offset + jitter;
      pos = Math.min(Math.max(pos, 0), interleaved.length);
      interleaved.splice(pos, 0, shuffledValidity[i]);
      offset += 1;
    }
  }

  const MIN_GAP_RETEST = 10; // hard floor
  const idealGapRetest = () => 15 + Math.floor(Math.random() * 6); // 15..20

  for (const rt of fisherYates(retestItems)) {
    const origIdx = interleaved.findIndex((it) => it.item_number === rt.retest_of_item_number);
    if (origIdx === -1) {
      interleaved.push(rt);
      continue;
    }
    const traitKey = rt.hypothesized_trait ?? null;
    const domainKey = rt.cognitive_domain ?? null;
    const key = traitKey ?? domainKey;
    const keyGetter = traitKey != null
      ? (it: T) => it.hypothesized_trait ?? null
      : (it: T) => it.cognitive_domain ?? null;
    const target = insertRetestSafely(interleaved, origIdx, MIN_GAP_RETEST, idealGapRetest(), key, keyGetter);
    interleaved.splice(target, 0, rt);
  }

  return interleaved;
}

type ExpansionTarget = {
  section: string | null;
  trait: string | null;
  nonsense_only: boolean;
  retest_only: boolean;
  cap: number | null;
};

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

      case "expand_impression_mgmt_and_nonsense":
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
        addTarget({
          section: null,
          trait: null,
          nonsense_only: false,
          retest_only: true,
          cap: t.expansion_count ?? null,
        });
        break;
    }
  }

  return Array.from(map.values());
}

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

    const { data: respRows, error: rErr } = await supa
      .from("hiregauge_candidate_responses")
      .select("item_id")
      .eq("candidate_id", cand.id)
      .eq("sitting", 1);
    if (rErr) return json({ error: "responses_fetch_failed", detail: rErr.message }, 500);
    const answered = new Set((respRows || []).map((r: any) => r.item_id));

    if (!prog.primaryAnswered) {
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

      const assigned = selectStint1ItemIdsForCandidate(cand.id, items || []);
      const assignedItems = (items || []).filter((it: any) => assigned.has(it.id));
      const unanswered = assignedItems.filter((it: any) => !answered.has(it.id));
      return json({
        stint: 1,
        done: unanswered.length === 0,
        items: constrainedShuffle(unanswered),
        progress: { answered: prog.answered, total: prog.total },
      });
    }

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

  let is_correct: boolean | null = null;
  if (item.answer_key != null && response_label != null) {
    is_correct = String(response_label).trim() === String(item.answer_key).trim();
  }

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
  try {
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

    const { data: pm, error: pmErr } = await supa.rpc(
      "compute_newtworks_v1_traits_as_row",
      { p_candidate_id: cand.id, p_stint: null, p_sitting: 1 }
    );
    if (pmErr) {
      return json({ error: "merged_compute_failed", detail: pmErr.message }, 500);
    }
    const rm = Array.isArray(pm) ? pm[0] : pm;

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

    let bandsRow: { reliability: string | null; response_distortion: string | null } = {
      reliability: null,
      response_distortion: null,
    };
    try {
      const { data: bandsData, error: bandsErr } = await supa.rpc(
        "compute_newtworks_v1_bands",
        { p_candidate_id: cand.id, p_stint: null, p_sitting: 1 }
      );
      if (!bandsErr) {
        const b = Array.isArray(bandsData) ? bandsData[0] : bandsData;
        bandsRow = {
          reliability: b?.reliability ?? null,
          response_distortion: b?.response_distortion ?? null,
        };
      }
    } catch (_bandsExc) {
      // Silent — see note above.
    }

    let updated = false;
    let update_skip_reason: string | null = null;
    if ((rm?.n_items_scored ?? 0) > 0 && rm?.overall_score != null) {
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
          reliability:             bandsRow.reliability,
          response_distortion:     bandsRow.response_distortion,
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
          const { data: fullCand } = await supa
            .from("hiring_candidates")
            .select("first_name, last_name, position")
            .eq("id", cand.id)
            .maybeSingle();
          const candName =
            [fullCand?.first_name, fullCand?.last_name].filter(Boolean).join(" ") ||
            "Unknown candidate";
          const position = fullCand?.position || "unspecified role";

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

// ============================================================================
// --- v2 handlers ---
// v2 stint 1 = integrity gate (33 items, all served, no rotation).
// v2 stint 2 = 6-item baseline per facet (~140 items, all served).
// v2 stint 3 = conditional expansion (up to 4 items per triggered facet,
// pulled from the already-published items held back from Stint 2 — see
// compute_newtworks_v2_stint3_triggers and header comment).
// ============================================================================

async function loadStintItemsV2(supa: any, stint: number) {
  const { data, error } = await supa
    .from("hiregauge_instrument_items")
    .select(
      "id, section, item_number, item_text, choices, scale_max, is_nonsense, hypothesized_trait, cognitive_domain, reverse_coded, retest_of_item_number"
    )
    .eq("stint", stint)
    .eq("is_active", true)
    .in("section", V2_SECTIONS)
    .order("section", { ascending: true })
    .order("item_number", { ascending: true });
  if (error) throw new Error(`v2_stint_${stint}_items_fetch: ${error.message}`);
  return data || [];
}

async function loadAnsweredV2(supa: any, candidateId: string): Promise<Set<string>> {
  const { data, error } = await supa
    .from("hiregauge_candidate_responses")
    .select("item_id")
    .eq("candidate_id", candidateId)
    .eq("sitting", 1);
  if (error) throw new Error(`v2_responses_fetch: ${error.message}`);
  return new Set((data || []).map((r: any) => r.item_id));
}

// Stint 3 targets: the ambiguous-facet retest items, computed only once
// Stint 1 + Stint 2 are both fully answered (the trigger reads the merged
// score, so it can't fire early).
async function loadStint3TargetsV2(supa: any, candidateId: string) {
  const { data, error } = await supa.rpc("compute_newtworks_v2_stint3_triggers", {
    p_candidate_id: candidateId,
  });
  if (error) throw new Error(`v2_stint3_triggers_fetch: ${error.message}`);
  const traits = new Set(((data || []) as any[]).map((r) => r.hypothesized_trait));
  if (traits.size === 0) return [];

  const { data: items, error: iErr } = await supa
    .from("hiregauge_instrument_items")
    .select(
      "id, section, item_number, item_text, choices, scale_max, is_nonsense, hypothesized_trait, cognitive_domain, reverse_coded, retest_of_item_number"
    )
    .eq("stint", 3)
    .eq("is_active", true)
    .in("section", V2_SECTIONS)
    .in("hypothesized_trait", Array.from(traits))
    .order("item_number", { ascending: true });
  if (iErr) throw new Error(`v2_stint3_items_fetch: ${iErr.message}`);

  // Cap at 4 items per triggered facet, per spec ("2-4 items per triggered
  // facet" -- some facets' leftover pool has more than 4 items, e.g.
  // compassion has 6; only the first 4 by item_number get served).
  const perTraitCount: Record<string, number> = {};
  const capped: any[] = [];
  for (const it of items || []) {
    const trait = it.hypothesized_trait ?? "";
    perTraitCount[trait] = (perTraitCount[trait] || 0) + 1;
    if (perTraitCount[trait] <= 4) capped.push(it);
  }
  return capped;
}

async function loadProgressV2(supa: any, candidateId: string) {
  const stint1Items = await loadStintItemsV2(supa, 1);
  const stint2Items = await loadStintItemsV2(supa, 2);
  const answered = await loadAnsweredV2(supa, candidateId);

  const stint1Answered = stint1Items.filter((it: any) => answered.has(it.id)).length;
  const stint1Done = stint1Items.length > 0 && stint1Answered >= stint1Items.length;

  const stint2Answered = stint2Items.filter((it: any) => answered.has(it.id)).length;
  const stint2Done = stint1Done && stint2Items.length > 0 && stint2Answered >= stint2Items.length;

  // Stint 3 is only computable once stint 1+2 are both done (trigger reads
  // the merged score). Before that, treat it as "not yet known."
  let stint3Items: any[] = [];
  let stint3Answered = 0;
  let stint3Done = false;
  if (stint2Done) {
    stint3Items = await loadStint3TargetsV2(supa, candidateId);
    stint3Answered = stint3Items.filter((it: any) => answered.has(it.id)).length;
    stint3Done = stint3Items.length === 0 || stint3Answered >= stint3Items.length;
  }

  return {
    stint1Items,
    stint2Items,
    stint3Items,
    answered,
    stint1Total: stint1Items.length,
    stint1Answered,
    stint1Done,
    stint2Total: stint2Items.length,
    stint2Answered,
    stint2Done,
    stint3Total: stint3Items.length,
    stint3Answered,
    stint3Done,
  };
}

async function handleVerifyV2(supa: any, cand: any) {
  try {
    const prog = await loadProgressV2(supa, cand.id);
    const allDone = prog.stint1Done && prog.stint2Done && prog.stint3Done;
    const currentProgress = !prog.stint1Done
      ? { answered: prog.stint1Answered, total: prog.stint1Total }
      : !prog.stint2Done
      ? { answered: prog.stint2Answered, total: prog.stint2Total }
      : { answered: prog.stint3Answered, total: prog.stint3Total };
    return json({
      ok: true,
      candidate: { first_name: cand.first_name, position: cand.position },
      primary_answered: prog.stint1Done,
      expansion_ready: prog.stint2Done && prog.stint3Total > 0,
      done: allDone,
      progress: currentProgress,
    });
  } catch (e: any) {
    return json({ error: "verify_action_failed", detail: e.message }, 500);
  }
}

async function handleServeV2(supa: any, cand: any) {
  try {
    const prog = await loadProgressV2(supa, cand.id);

    if (!prog.stint1Done) {
      const unanswered = prog.stint1Items.filter((it: any) => !prog.answered.has(it.id));
      return json({
        stint: 1,
        done: unanswered.length === 0,
        items: constrainedShuffle(unanswered),
        progress: { answered: prog.stint1Answered, total: prog.stint1Total },
      });
    }

    if (!prog.stint2Done) {
      const unanswered = prog.stint2Items.filter((it: any) => !prog.answered.has(it.id));
      return json({
        stint: 2,
        done: unanswered.length === 0,
        items: constrainedShuffle(unanswered),
        progress: { answered: prog.stint2Answered, total: prog.stint2Total },
      });
    }

    // Stint 3: only the ambiguous facets' retest items, or none at all.
    if (prog.stint3Total === 0) {
      return json({ stint: 3, done: true, items: [], progress: { answered: 0, total: 0 } });
    }
    const unanswered = prog.stint3Items.filter((it: any) => !prog.answered.has(it.id));
    return json({
      stint: 3,
      done: unanswered.length === 0,
      items: constrainedShuffle(unanswered),
      progress: { answered: prog.stint3Answered, total: prog.stint3Total },
    });
  } catch (e: any) {
    return json({ error: "serve_action_failed", detail: e.message }, 500);
  }
}

async function handleSaveV2(supa: any, cand: any, body: any) {
  const { item_id, response_value, response_label, served_at } = body ?? {};
  if (!item_id) return json({ error: "missing_item_id" }, 400);
  if (response_value == null && response_label == null) {
    return json({ error: "missing_response" }, 400);
  }

  const { data: item, error: iErr } = await supa
    .from("hiregauge_instrument_items")
    .select("id, section, stint, is_active, answer_key")
    .eq("id", item_id)
    .maybeSingle();
  if (iErr) return json({ error: "item_fetch_failed", detail: iErr.message }, 500);
  if (!item) return json({ error: "item_not_found" }, 404);
  if (!V2_SECTIONS.includes(item.section) || item.stint == null || !item.is_active) {
    return json({ error: "item_not_v2_active" }, 400);
  }

  let is_correct: boolean | null = null;
  if (item.answer_key != null && response_label != null) {
    is_correct = String(response_label).trim() === String(item.answer_key).trim();
  }

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

  try {
    await supa
      .from("hiring_candidates")
      .update({ assessment_started_at: answered_at_iso })
      .eq("id", cand.id)
      .eq("agency_id", AGENCY_ID)
      .is("assessment_started_at", null);
  } catch (_e) {
    // Silent — timing capture is diagnostic, not a correctness gate.
  }

  return json({ ok: true });
}

// Maps hypothesized_trait -> hiring_candidates column name for the v2 facet
// write-back. 1:1 with migration 20260731194800's 21 parallel columns.
const V2_FACET_COLUMNS: Record<string, string> = {
  achievement_striving: "achievement_striving",
  self_discipline: "self_discipline",
  emotional_stability: "emotional_stability",
  perseverance: "perseverance",
  dutifulness: "dutifulness",
  customer_orientation: "customer_orientation",
  self_efficacy: "self_efficacy",
  proactive_personality: "proactive_personality",
  cautiousness: "cautiousness",
  anxiety: "anxiety",
  friendliness: "friendliness",
  anger: "anger",
  cooperation: "cooperation",
  trust: "trust",
  assured_dominance: "assured_dominance",
  dispositional_optimism: "dispositional_optimism",
  political_skill_networking: "political_skill_networking",
  enterprising: "enterprising",
  sincerity: "sincerity",
  fairness: "fairness",
  greed_avoidance: "greed_avoidance",
};

async function handleFinalizeV2(supa: any, cand: any) {
  try {
    const prog = await loadProgressV2(supa, cand.id);
    if (!prog.stint1Done) {
      return json(
        {
          error: "assessment_incomplete",
          stage: "stint_1",
          answered: prog.stint1Answered,
          total: prog.stint1Total,
        },
        409
      );
    }
    if (prog.stint2Total > 0 && !prog.stint2Done) {
      return json(
        {
          error: "assessment_incomplete",
          stage: "stint_2",
          answered: prog.stint2Answered,
          total: prog.stint2Total,
        },
        409
      );
    }
    if (prog.stint3Total > 0 && !prog.stint3Done) {
      return json(
        {
          error: "assessment_incomplete",
          stage: "stint_3",
          answered: prog.stint3Answered,
          total: prog.stint3Total,
        },
        409
      );
    }

    // Merged (both stints) facet scores — the raw psychometric profile.
    // Competency/role-fit derivation from these facets is NOT done here
    // (deferred, OQ f979e377).
    const { data: facetRows, error: facetErr } = await supa.rpc(
      "compute_newtworks_v2_facets_as_row",
      { p_candidate_id: cand.id, p_stint: null, p_sitting: 1 }
    );
    if (facetErr) {
      return json({ error: "facet_compute_failed", detail: facetErr.message }, 500);
    }

    const rows = (facetRows || []) as Array<{
      hypothesized_trait: string;
      facet_score: number;
      n_items_scored: number;
    }>;

    const updatePayload: Record<string, any> = {};
    let totalItemsScored = 0;
    for (const row of rows) {
      const col = V2_FACET_COLUMNS[row.hypothesized_trait];
      if (!col) continue; // unmapped trait — skip rather than guess a column
      updatePayload[col] = row.facet_score;
      totalItemsScored += row.n_items_scored;
    }

    let updated = false;
    let update_skip_reason: string | null = null;
    if (Object.keys(updatePayload).length > 0) {
      const finalized_at_iso = new Date().toISOString();
      updatePayload.v2 = true;
      updatePayload.assessment_source = "v2";
      updatePayload.assessment_date = finalized_at_iso.slice(0, 10);
      updatePayload.assessment_completed_at = finalized_at_iso;

      const { error: upErr } = await supa
        .from("hiring_candidates")
        .update(updatePayload)
        .eq("id", cand.id)
        .eq("agency_id", AGENCY_ID);
      if (upErr) {
        return json({ error: "flat_update_failed", detail: upErr.message }, 500);
      }
      updated = true;

      try {
        await supa.rpc("apply_newtworks_v2_reliability_to_candidate", {
          p_candidate_id: cand.id,
        });
      } catch (_relErr) {
        // Silent — reliability composite is diagnostic, not a correctness gate.
      }
    } else {
      update_skip_reason = "no_facets_scored";
    }

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

    let notification_fired = false;
    let notification_skip_reason: string | null = null;
    if (updated) {
      try {
        const { data: existing } = await supa
          .from("alerts")
          .select("id")
          .eq("agency_id", AGENCY_ID)
          .eq("alert_type", "v2_assessment_complete")
          .eq("related_id", cand.id)
          .limit(1)
          .maybeSingle();

        if (existing) {
          notification_skip_reason = "already_notified";
        } else {
          const { data: fullCand } = await supa
            .from("hiring_candidates")
            .select("first_name, last_name, position")
            .eq("id", cand.id)
            .maybeSingle();
          const candName =
            [fullCand?.first_name, fullCand?.last_name].filter(Boolean).join(" ") ||
            "Unknown candidate";
          const position = fullCand?.position || "unspecified role";

          const link = `https://newtworks.vercel.app/?module=team&candidate=${cand.id}`;
          const title = `v2 assessment complete: ${candName}`;
          const message =
            `${candName} finished the Newtworks v2 assessment for ${position}. ` +
            `${rows.length} facets scored, ${totalItemsScored} items total. ` +
            `Competency/role-fit scoring not yet available for v2 (in progress) — ` +
            `raw facet profile only. View: ${link}`;

          const { error: alertErr } = await supa.from("alerts").insert({
            agency_id: AGENCY_ID,
            alert_type: "v2_assessment_complete",
            severity: "info",
            title,
            message,
            module_reference: "hiring",
            related_id: cand.id,
            is_read: false,
            is_resolved: false,
          });
          if (alertErr) throw new Error(`alert_insert_failed: ${alertErr.message}`);

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
              `\u{1F4DD} v2 assessment complete: ${candName} (${position})\n` +
              `${rows.length} facets scored \u00B7 ${totalItemsScored} items \u00B7 raw profile only (competency scoring pending)\n` +
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
      facets_scored: rows.length,
      total_items_scored: totalItemsScored,
    });
  } catch (e: any) {
    return json({ error: "finalize_action_failed", detail: e.message }, 500);
  }
}
