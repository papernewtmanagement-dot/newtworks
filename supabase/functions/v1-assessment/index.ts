// supabase/functions/v1-assessment/index.ts
// Newtworks assessment — public candidate endpoint. Folder/function name kept
// as-is (v1-assessment) to avoid a frontend URL/route change, but there is no
// longer a v1/v2 fork: this function serves ONE assessment — whatever is
// currently configured as active in hiregauge_instrument_items — to every
// candidate who gets a link. No per-candidate switch, no legacy fallback.
//
// REWRITTEN 2026-08-02: removed the hiring_candidates.v2 branch and every v1
// handler entirely (Peter directive: "when an assessment is served, it
// should be the current assessment" — a dual-path switch was never the
// right model). This also unblocks dropping the 13 legacy v1 scoring
// functions and the hiring_candidates.v2 column (see op-rule "Newtworks
// commits — canonical path" session log, Steps 8/9).
//
// Same session: wired GMA (cognitive) and SJT (situational judgment) into
// the serving flow for the first time. Previously both sections existed in
// hiregauge_instrument_items but were excluded from SECTIONS, so they were
// inert regardless of their stint value.
//
// Structure (4 stints):
//   - Stint 1 = integrity gate (33 HEXACO Honesty-Humility items: sincerity,
//     fairness, greed_avoidance) + GMA cognitive floor (16 active items, 4
//     per subtest: pattern/deductive/numerical/verbal). Served in full, no
//     rotation, unconditional.
//   - Stint 2 = 6-item baseline per personality facet (~140 items). Served
//     in full once Stint 1 is complete.
//   - Stint 3 = up to 4 leftover items per facet whose Stint 1+2 score lands
//     in the ambiguous 45-55 band (compute_newtworks_v2_stint3_triggers).
//     Pulled from the SAME already-published, already-cited scale used for
//     Stint 2 — not new content, not a retest. Conditional; may be empty.
//   - Stint 4 = SJT (40 items, 10 competencies x 4 items each). Served in
//     full once Stint 3 is resolved (whether or not it triggered any
//     facets), unconditional, same pattern as Stint 2 — not trigger-gated.
//   - Retest items (1 per personality facet, all 22) are separate from
//     Stint 3 — within-sitting consistency checks (Meade & Craig 2012).
//     They live in Stint 1 or 2 alongside their facet's baseline items and
//     are always served.
//   - Scoring on finalize: compute_newtworks_v2_facets_as_row (personality
//     facets), apply_newtworks_gma_to_candidate (GMA accuracy + speed per
//     domain), apply_newtworks_v2_sjt_to_candidate (SJT % correct per
//     construct), apply_newtworks_v2_reliability_to_candidate
//     (careless-response composite), apply_newtworks_v2_competency_gates_to_
//     candidate (Newtworks competency layer — 12 competencies x 7 roles,
//     confirmed 2026-08-02, live 2026-08-03: determines best-fit role, then
//     persists which gates fired — integrity decline / critical-floor /
//     reasoning-floor — plus the churn-risk flag, wired in Step 9). All five
//     are independent and best-effort at finalize — one failing does not
//     block the others or the core facet write.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// The current assessment's sections. Extend this array (not the function
// structure) when new sections come online.
const SECTIONS = [
  "newtworks_v2_personality",
  "newtworks_v2_cognitive_gma",
  "newtworks_v2_sjt",
  "newtworks_v2_screen",
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

  const { data: verifyOk, error: verifyErr } = await supa.rpc(
    "verify_v1_assessment_token",
    { p_candidate_id: candidate_id, p_token: token }
  );
  if (verifyErr) return json({ error: "verify_failed", detail: verifyErr.message }, 500);
  if (verifyOk !== true) return json({ error: "invalid_token" }, 403);

  const { data: cand, error: candErr } = await supa
    .from("hiring_candidates")
    .select("id, first_name, position, assessment_exit_gate")
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

// ============================================================================
// --- item ordering (unchanged from prior version) ---
// ============================================================================

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
// directions — forward-only search can fail entirely when the original
// lands too close to the array's end (confirmed via reproduction: an
// original at position 145 in a 151-item array left only 6 slots of room).
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

  const fwd = scan(Math.min(origIdx + idealGap, n), n) ?? scan(Math.max(origIdx + minGap, 0), n);
  if (fwd != null) return fwd;

  const back = scan(0, Math.max(origIdx - idealGap, -1)) ?? scan(0, Math.max(origIdx - minGap + 1, -1));
  if (back != null) return back;

  for (let target = 0; target <= n; target++) {
    if (isSafe(target)) return target;
  }

  return Math.min(origIdx + idealGap, n);
}

// Round-robin trait/domain interleaving via cooldown-based greedy
// scheduling. Standard psychometric test-construction practice per Nunnally
// & Bernstein 1994 (ch. 8) and Anastasi & Urbina 1997 (ch. 3-4). See
// op-rule "v2 assessment — shuffle algorithm structural defect, replaced
// with round-robin interleaving 2026-08-02" for the failure history of the
// prior greedy forward-swap heuristic — do not restore it.
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

  const MIN_GAP_RETEST = 10; // hard floor — do not raise to 15, see op-rule
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

// ============================================================================
// --- stint loading + progress ---
// ============================================================================

const ITEM_SELECT =
  "id, section, item_number, item_text, choices, scale_max, is_nonsense, hypothesized_trait, cognitive_domain, reverse_coded, retest_of_item_number, response_format";

async function loadStintItems(supa: any, stint: number) {
  const { data, error } = await supa
    .from("hiregauge_instrument_items")
    .select(ITEM_SELECT)
    .eq("stint", stint)
    .eq("is_active", true)
    .in("section", SECTIONS)
    .order("section", { ascending: true })
    .order("item_number", { ascending: true });
  if (error) throw new Error(`stint_${stint}_items_fetch: ${error.message}`);
  return data || [];
}

async function loadAnswered(supa: any, candidateId: string): Promise<Set<string>> {
  const { data, error } = await supa
    .from("hiregauge_candidate_responses")
    .select("item_id")
    .eq("candidate_id", candidateId)
    .eq("sitting", 1);
  if (error) throw new Error(`responses_fetch: ${error.message}`);
  return new Set((data || []).map((r: any) => r.item_id));
}

// Stint 3 targets: ambiguous-facet leftover-pool items, computed only once
// Stint 1 + Stint 2 are both fully answered (the trigger reads the merged
// score, so it can't fire early). SJT/GMA never trigger Stint 3 — the
// trigger function only reads personality facet scores.
async function loadStint3Targets(supa: any, candidateId: string) {
  const { data, error } = await supa.rpc("compute_newtworks_v2_stint3_triggers", {
    p_candidate_id: candidateId,
  });
  if (error) throw new Error(`stint3_triggers_fetch: ${error.message}`);
  const traits = new Set(((data || []) as any[]).map((r) => r.hypothesized_trait));
  if (traits.size === 0) return [];

  const { data: items, error: iErr } = await supa
    .from("hiregauge_instrument_items")
    .select(ITEM_SELECT)
    .eq("stint", 3)
    .eq("is_active", true)
    .in("section", SECTIONS)
    .in("hypothesized_trait", Array.from(traits))
    .order("item_number", { ascending: true });
  if (iErr) throw new Error(`stint3_items_fetch: ${iErr.message}`);

  // Cap at 4 items per triggered facet, per spec ("2-4 items per triggered
  // facet" — some facets' leftover pool has more than 4 items).
  const perTraitCount: Record<string, number> = {};
  const capped: any[] = [];
  for (const it of items || []) {
    const trait = it.hypothesized_trait ?? "";
    perTraitCount[trait] = (perTraitCount[trait] || 0) + 1;
    if (perTraitCount[trait] <= 4) capped.push(it);
  }
  return capped;
}

async function loadProgress(supa: any, candidateId: string) {
  const stint1Items = await loadStintItems(supa, 1);
  const stint2Items = await loadStintItems(supa, 2);
  const stint4Items = await loadStintItems(supa, 4);
  const stint5Items = await loadStintItems(supa, 5);
  const answered = await loadAnswered(supa, candidateId);

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
    stint3Items = await loadStint3Targets(supa, candidateId);
    stint3Answered = stint3Items.filter((it: any) => answered.has(it.id)).length;
    stint3Done = stint3Items.length === 0 || stint3Answered >= stint3Items.length;
  }

  // Stint 4 (SJT) is unconditional, like stint 2 — not trigger-gated — but
  // only reachable once stint 3 is resolved (whether or not it triggered).
  const stint4Answered = stint4Items.filter((it: any) => answered.has(it.id)).length;
  const stint4Done = stint3Done && (stint4Items.length === 0 || stint4Answered >= stint4Items.length);

  // Stint 5 (written screen — "Part 2") is unconditional, same pattern as
  // stint 2/4 — not trigger-gated — reachable once stint 4 is done. Added
  // 2026-08-06: in-app replacement for the emailed Part 2 flow. Filter
  // economics are inherited for free — a candidate only reaches stint 5 by
  // clearing every earlier stint's exit gates, so there is no separate
  // "clears CTS" condition to reproduce here.
  const stint5Answered = stint5Items.filter((it: any) => answered.has(it.id)).length;
  const stint5Done = stint4Done && (stint5Items.length === 0 || stint5Answered >= stint5Items.length);

  return {
    stint1Items, stint2Items, stint3Items, stint4Items, stint5Items, answered,
    stint1Total: stint1Items.length, stint1Answered, stint1Done,
    stint2Total: stint2Items.length, stint2Answered, stint2Done,
    stint3Total: stint3Items.length, stint3Answered, stint3Done,
    stint4Total: stint4Items.length, stint4Answered, stint4Done,
    stint5Total: stint5Items.length, stint5Answered, stint5Done,
  };
}

// --- answer-order randomisation --------------------------------------------
// Every scored section shipped with its correct answer in a fixed position: the
// 2nd option on all 20 scenarios, the last option on every shape item, the 1st
// option on every word item. A candidate picking one position throughout could
// score well without reading anything, which made the reasoning and scenario
// scores meaningless. Order is now permuted per candidate per item.
//
// The permutation is DETERMINISTIC on (candidate id, item id): a refresh
// re-serves the same order, and the save path can undo it to score the
// letter-keyed items. Never use Math.random here -- a fresh random order on
// every serve would make letter answers unscoreable.
//
// Any "none of these" option is pushed back to last after shuffling. It is the
// over-claiming escape hatch and it has to sit in a predictable place, or the
// made-up-word items stop measuring what they measure.
function seedFrom(a: string, b: string): number {
  const s = `${a}:${b}`;
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

function makeRng(seed: number): () => number {
  let t = seed >>> 0;
  return () => {
    t = (t + 0x6d2b79f5) >>> 0;
    let x = Math.imul(t ^ (t >>> 15), 1 | t);
    x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}

function seededShuffle<T>(arr: T[], seed: number): T[] {
  const rand = makeRng(seed);
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

const OPTION_LETTERS = ["A", "B", "C", "D", "E", "F"];

function isNoneOption(v: unknown): boolean {
  return typeof v === "string" && v.toLowerCase().includes("none of these");
}

function optionLetters(options: Record<string, unknown>): string[] {
  return OPTION_LETTERS.filter((L) => options[L] !== undefined);
}

// Display slot i shows whatever was originally stored under permutation[i].
function letterPermutation(candidateId: string, itemId: string, letters: string[]): string[] {
  return seededShuffle(letters, seedFrom(candidateId, itemId));
}

function prepareItem(item: any, candidateId: string): any {
  const out = { ...item };

  // The shape and number items keep their generator's solving rule in
  // item_text as authoring notes. The candidate page already hides it, but it
  // was still being shipped to the browser, where anyone could read the answer
  // rule straight out of the network tab.
  if (out.cognitive_domain === "gma_pattern" || out.cognitive_domain === "gma_numerical") {
    out.item_text = "";
  }

  const ch = out.choices;

  if (Array.isArray(ch) && ch.length > 1) {
    const shuffled = seededShuffle(ch, seedFrom(candidateId, out.id));
    const idx = shuffled.findIndex(isNoneOption);
    if (idx !== -1 && idx !== shuffled.length - 1) {
      const [none] = shuffled.splice(idx, 1);
      shuffled.push(none);
    }
    out.choices = shuffled;
    return out;
  }

  if (ch && typeof ch === "object" && !Array.isArray(ch) && ch.options && typeof ch.options === "object") {
    const letters = optionLetters(ch.options);
    if (letters.length > 1) {
      const perm = letterPermutation(candidateId, out.id, letters);
      const remapped: Record<string, unknown> = {};
      letters.forEach((displayLetter, i) => {
        remapped[displayLetter] = ch.options[perm[i]];
      });
      out.choices = { ...ch, options: remapped };
    }
    return out;
  }

  return out;
}

function prepareItems(items: any[], candidateId: string): any[] {
  return items.map((it) => prepareItem(it, candidateId));
}

// Turn the letter the candidate clicked back into the letter the answer key is
// written against. Exact inverse of the permutation applied at serve time.
function canonicalLetter(reported: string, item: any, candidateId: string): string {
  const ch = item?.choices;
  if (!ch || Array.isArray(ch) || typeof ch !== "object") return reported;
  if (!ch.options || typeof ch.options !== "object") return reported;
  const letters = optionLetters(ch.options);
  const slot = letters.indexOf(reported);
  if (slot === -1) return reported;
  return letterPermutation(candidateId, item.id, letters)[slot];
}

// --- Stint 1 exit gate ------------------------------------------------------
// Runs once Stint 1 is complete, immediately before Stint 2 would be served.
// The candidate is never told that a gate fired: they get the same neutral
// completion screen as anyone who finishes. The reason goes to the owner only,
// via an alerts row and a Telegram message. Every response already collected
// is kept. Thresholds and their rationale live in the SQL function docstring
// (hiregauge_v2_stint1_exit_gate).
async function exitGateFired(supa: any, cand: any): Promise<boolean> {
  if (cand.assessment_exit_gate) return true;
  try {
    const { data, error } = await supa.rpc("apply_hiregauge_v2_stint1_exit_gate", {
      p_candidate_id: cand.id,
      p_sitting: 1,
    });
    // Never block a candidate because the gate itself errored.
    if (error) return false;
    return Boolean(data?.gate_fired);
  } catch (_e) {
    return false;
  }
}

function exitedResponse() {
  return json({
    stint: 1,
    done: true,
    exited: true,
    items: [],
    progress: { answered: 0, total: 0 },
  });
}

async function handleVerify(supa: any, cand: any) {
  try {
    if (cand.assessment_exit_gate) {
      return json({
        ok: true,
        candidate: { first_name: cand.first_name, position: cand.position },
        primary_answered: true,
        expansion_ready: false,
        done: true,
        exited: true,
        progress: { answered: 0, total: 0 },
      });
    }
    const prog = await loadProgress(supa, cand.id);
    const allDone = prog.stint1Done && prog.stint2Done && prog.stint3Done && prog.stint4Done && prog.stint5Done;
    const currentProgress = !prog.stint1Done
      ? { answered: prog.stint1Answered, total: prog.stint1Total }
      : !prog.stint2Done
      ? { answered: prog.stint2Answered, total: prog.stint2Total }
      : !prog.stint3Done
      ? { answered: prog.stint3Answered, total: prog.stint3Total }
      : !prog.stint4Done
      ? { answered: prog.stint4Answered, total: prog.stint4Total }
      : { answered: prog.stint5Answered, total: prog.stint5Total };
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

async function handleServe(supa: any, cand: any) {
  try {
    if (cand.assessment_exit_gate) return exitedResponse();

    const prog = await loadProgress(supa, cand.id);

    if (!prog.stint1Done) {
      const unanswered = prog.stint1Items.filter((it: any) => !prog.answered.has(it.id));
      return json({
        stint: 1,
        done: unanswered.length === 0,
        items: prepareItems(constrainedShuffle(unanswered), cand.id),
        progress: { answered: prog.stint1Answered, total: prog.stint1Total },
      });
    }

    if (await exitGateFired(supa, cand)) return exitedResponse();

    if (!prog.stint2Done) {
      const unanswered = prog.stint2Items.filter((it: any) => !prog.answered.has(it.id));
      return json({
        stint: 2,
        done: unanswered.length === 0,
        items: prepareItems(constrainedShuffle(unanswered), cand.id),
        progress: { answered: prog.stint2Answered, total: prog.stint2Total },
      });
    }

    if (!prog.stint3Done) {
      const unanswered = prog.stint3Items.filter((it: any) => !prog.answered.has(it.id));
      return json({
        stint: 3,
        done: unanswered.length === 0,
        items: prepareItems(constrainedShuffle(unanswered), cand.id),
        progress: { answered: prog.stint3Answered, total: prog.stint3Total },
      });
    }

    if (prog.stint4Total === 0) {
      return json({ stint: 4, done: true, items: [], progress: { answered: 0, total: 0 } });
    }
    const unanswered = prog.stint4Items.filter((it: any) => !prog.answered.has(it.id));
    return json({
      stint: 4,
      done: unanswered.length === 0,
      items: prepareItems(constrainedShuffle(unanswered), cand.id),
      progress: { answered: prog.stint4Answered, total: prog.stint4Total },
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
    .select("id, section, stint, is_active, answer_key, choices")
    .eq("id", item_id)
    .maybeSingle();
  if (iErr) return json({ error: "item_fetch_failed", detail: iErr.message }, 500);
  if (!item) return json({ error: "item_not_found" }, 404);
  if (!SECTIONS.includes(item.section) || item.stint == null || !item.is_active) {
    return json({ error: "item_not_active" }, 400);
  }

  // Letter-keyed items were served with their options permuted, so the letter
  // the candidate clicked is a display slot, not the stored letter. Translate it
  // back before scoring, and store the canonical letter so a saved response
  // stays interpretable without replaying the permutation.
  let canonical_label: string | null =
    response_label == null ? null : String(response_label).trim();
  if (canonical_label != null) {
    canonical_label = canonicalLetter(canonical_label, item, cand.id);
  }

  let is_correct: boolean | null = null;
  if (item.answer_key != null && canonical_label != null) {
    is_correct = canonical_label === String(item.answer_key).trim();
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
        response_label: canonical_label ?? null,
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

// Maps hypothesized_trait -> hiring_candidates column name for the
// personality facet write-back. 1:1 with migration 20260731194800's 21
// parallel columns.
const FACET_COLUMNS: Record<string, string> = {
  achievement_striving: "achievement_striving",
  competitiveness: "competitiveness",
  learning_goal_orientation: "learning_goal_orientation",
  prove_goal_orientation: "prove_goal_orientation",
  avoid_goal_orientation: "avoid_goal_orientation",
  self_discipline: "self_discipline",
  emotional_stability: "emotional_stability",
  assertiveness: "assertiveness",
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
  compassion: "compassion",
  dispositional_optimism: "dispositional_optimism",
  political_skill_networking: "political_skill_networking",
  enterprising: "enterprising",
  sincerity: "sincerity",
  fairness: "fairness",
  greed_avoidance: "greed_avoidance",
};

async function handleFinalize(supa: any, cand: any) {
  try {
    if (cand.assessment_exit_gate) {
      return json({ ok: true, done: true, exited: true });
    }
    const prog = await loadProgress(supa, cand.id);
    if (!prog.stint1Done) {
      return json({ error: "assessment_incomplete", stage: "stint_1", answered: prog.stint1Answered, total: prog.stint1Total }, 409);
    }
    if (prog.stint2Total > 0 && !prog.stint2Done) {
      return json({ error: "assessment_incomplete", stage: "stint_2", answered: prog.stint2Answered, total: prog.stint2Total }, 409);
    }
    if (prog.stint3Total > 0 && !prog.stint3Done) {
      return json({ error: "assessment_incomplete", stage: "stint_3", answered: prog.stint3Answered, total: prog.stint3Total }, 409);
    }
    if (prog.stint4Total > 0 && !prog.stint4Done) {
      return json({ error: "assessment_incomplete", stage: "stint_4", answered: prog.stint4Answered, total: prog.stint4Total }, 409);
    }

    // Personality facet scores — the raw psychometric profile. Competency
    // and role-fit derivation happen downstream (newtworks_competency_*,
    // newtworks_role_fit_*, assessment_best_fit_role) reading these columns
    // live at request time — nothing about competencies gets written here
    // except the gate-fired/churn-risk summary a few blocks below.
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
      const col = FACET_COLUMNS[row.hypothesized_trait];
      if (!col) continue; // unmapped trait — skip rather than guess a column
      updatePayload[col] = row.facet_score;
      totalItemsScored += row.n_items_scored;
    }

    let updated = false;
    let update_skip_reason: string | null = null;
    if (Object.keys(updatePayload).length > 0) {
      const finalized_at_iso = new Date().toISOString();
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
    } else {
      update_skip_reason = "no_facets_scored";
    }

    // GMA, SJT, reliability composite — independent, best-effort. Any one
    // failing does not block the others or the core facet write above.
    let gma_result: any = null;
    try {
      const { data, error } = await supa.rpc("apply_newtworks_gma_to_candidate", { p_candidate_id: cand.id });
      gma_result = error ? { error: error.message } : data;
    } catch (e: any) {
      gma_result = { error: e?.message ?? "unknown" };
    }

    let sjt_result: any = null;
    try {
      const { data, error } = await supa.rpc("apply_newtworks_v2_sjt_to_candidate", { p_candidate_id: cand.id });
      sjt_result = error ? { error: error.message } : data;
    } catch (e: any) {
      sjt_result = { error: e?.message ?? "unknown" };
    }

    let im_result: any = null;
    try {
      const { data, error } = await supa.rpc(
        "apply_newtworks_v2_impression_management_to_candidate",
        { p_candidate_id: cand.id }
      );
      im_result = error ? { error: error.message } : data;
    } catch (e: any) {
      im_result = { error: e?.message ?? "unknown" };
    }

    // Competency gates — determines best-fit role, then persists whichever
    // gate fired (integrity decline / critical-floor / reasoning-floor) plus
    // the churn-risk flag to hiring_candidates.competency_gate_fired /
    // competency_gate_detail / churn_risk. Runs only once the core facet
    // write succeeded (achievement_striving etc. must be populated, which is
    // the same gate _newtworks_role_fit_core checks).
    let competency_gates_result: any = null;
    if (updated) {
      try {
        const { data, error } = await supa.rpc(
          "apply_newtworks_v2_competency_gates_to_candidate",
          { p_candidate_id: cand.id }
        );
        competency_gates_result = error ? { error: error.message } : data;
      } catch (e: any) {
        competency_gates_result = { error: e?.message ?? "unknown" };
      }
    }

    if (updated) {
      try {
        await supa.rpc("apply_newtworks_v2_reliability_to_candidate", { p_candidate_id: cand.id });
      } catch (_relErr) {
        // Silent — reliability composite is diagnostic, not a correctness gate.
      }
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
          const title = `Assessment complete: ${candName}`;
          const message =
            `${candName} finished the Newtworks assessment for ${position}. ` +
            `${rows.length} personality facets scored, ${totalItemsScored} items. ` +
            `GMA + SJT + competency gates scored alongside. View: ${link}`;

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
              `\u{1F4DD} Assessment complete: ${candName} (${position})\n` +
              `${rows.length} facets \u00B7 ${totalItemsScored} items \u00B7 GMA + SJT + competency gates scored\n` +
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
      gma: gma_result,
      sjt: sjt_result,
      impression_management: im_result,
      competency_gates: competency_gates_result,
    });
  } catch (e: any) {
    return json({ error: "finalize_action_failed", detail: e.message }, 500);
  }
}
