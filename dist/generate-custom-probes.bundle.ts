// =========================================================================
// generate-custom-probes bundle (auto-generated)
// Source of truth: supabase/functions/generate-custom-probes/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py generate-custom-probes`.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getDocumentProxy, extractText as unpdfExtractText } from "npm:unpdf@1.3.2";

// ==================== _shared/supabase.ts ====================
// =========================================================================
// _shared/supabase.ts
// =========================================================================
// Canonical Supabase client + settings + response helpers for ALL Newtworks
// edge functions. Source of truth for code that used to be copy-pasted into
// every function (client creation, getSetting, jsonResponse, stripFences).
//
// Edge functions deploy as single-file bundles: `scripts/bundle_edge_fn.py`
// inlines this file into each function's bundle. Never edit a bundle by hand;
// edit here and rebundle every consumer.
// =========================================================================


const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Service role — bypasses RLS. Same client options every function used.
const sb: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Single-agency install. Functions that accept agency_id in the request body
// should still prefer the body value; this is the fallback.
const AGENCY_ID_DEFAULT = "126794dd-25ff-47d2-a436-724499733365";

// -------------------------------------------------------------------------
// Settings
// -------------------------------------------------------------------------
// Two variants on purpose — they preserve the two behaviors that existed in
// the wild before consolidation:
//   getSetting        — THROWS if the settings table read itself errors
//                       (infra failure ≠ missing row). Use on critical paths.
//   getSettingOrNull  — swallows read errors, returns null. Use where the
//                       caller treats "can't read" the same as "not set".
// Both return null when the row simply doesn't exist.
// -------------------------------------------------------------------------

async function getSetting(
  agencyId: string,
  key: string,
): Promise<string | null> {
  const { data, error } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  if (error) {
    throw new Error(
      `settings read failed for agency ${agencyId} key ${key}: ${error.message}`,
    );
  }
  return data?.setting_value ?? null;
}

async function getSettingOrNull(
  agencyId: string,
  key: string,
): Promise<string | null> {
  try {
    const { data } = await sb
      .from("settings")
      .select("setting_value")
      .eq("agency_id", agencyId)
      .eq("setting_key", key)
      .maybeSingle();
    return (data?.setting_value as string | null) ?? null;
  } catch (_e) {
    return null;
  }
}

// Batch read — one query for N keys. Missing keys come back as null.
async function getSettings(
  agencyId: string,
  keys: string[],
): Promise<Record<string, string | null>> {
  const out: Record<string, string | null> = {};
  for (const k of keys) out[k] = null;
  const { data, error } = await sb
    .from("settings")
    .select("setting_key,setting_value")
    .eq("agency_id", agencyId)
    .in("setting_key", keys);
  if (error) {
    throw new Error(`settings batch read failed for agency ${agencyId}: ${error.message}`);
  }
  for (const row of data ?? []) {
    out[(row as any).setting_key] = (row as any).setting_value ?? null;
  }
  return out;
}

// -------------------------------------------------------------------------
// HTTP responses
// -------------------------------------------------------------------------

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// -------------------------------------------------------------------------
// Text helpers
// -------------------------------------------------------------------------

// Strip ```json fences an LLM wrapped around its output.
function stripFences(s: string): string {
  return s
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/i, "")
    .trim();
}

// ==================== _shared/alerts.ts ====================
// =========================================================================
// _shared/alerts.ts
// =========================================================================
// Canonical alerts writer for ALL Newtworks edge functions.
//
// Why this exists: the alerts table takes (alert_type NOT NULL, severity,
// title, message, module_reference, related_id, is_resolved). Hand-written
// inserts have shipped with a `body:` column that does not exist and with
// alert_type missing — both fail silently when the insert result isn't
// checked. Going through this helper makes that class of bug impossible.
// =========================================================================


async function insertAlert(opts: {
  agencyId: string;
  alertType: string;
  severity: "info" | "warning" | "high" | "critical" | string;
  title: string;
  message: string;
  moduleReference?: string;
  relatedId?: string | null;
}): Promise<{ ok: boolean; error: string | null }> {
  const row: Record<string, unknown> = {
    agency_id: opts.agencyId,
    alert_type: opts.alertType,
    severity: opts.severity,
    title: opts.title,
    message: opts.message,
    is_read: false,
    is_resolved: false,
  };
  if (opts.moduleReference != null) row.module_reference = opts.moduleReference;
  if (opts.relatedId != null) row.related_id = opts.relatedId;

  const { error } = await sb.from("alerts").insert(row);
  if (error) {
    // Never throw — alerting must not mask the underlying failure being
    // reported. But do surface the miss to whoever reads the function logs.
    console.error(`insertAlert failed (${opts.alertType}): ${error.message}`);
    return { ok: false, error: error.message };
  }
  return { ok: true, error: null };
}

// Resolve all open alerts carrying a given module_reference (the standard
// "this condition cleared" pattern used by surepayroll + pfa flows).
async function resolveAlerts(opts: {
  agencyId: string;
  moduleReference: string;
}): Promise<{ ok: boolean; resolved: number; error: string | null }> {
  const { data, error } = await sb
    .from("alerts")
    .update({ is_resolved: true, resolved_at: new Date().toISOString() })
    .eq("agency_id", opts.agencyId)
    .eq("module_reference", opts.moduleReference)
    .eq("is_resolved", false)
    .select("id");
  if (error) {
    console.error(`resolveAlerts failed (${opts.moduleReference}): ${error.message}`);
    return { ok: false, resolved: 0, error: error.message };
  }
  return { ok: true, resolved: (data ?? []).length, error: null };
}

// ==================== _shared/composio.ts ====================
// =========================================================================
// _shared/composio.ts
// =========================================================================
// Canonical Composio HTTP wrapper for Newtworks edge functions.
//
// This file used to CLAIM to be "the one true copy" while three others
// existed: document-processor/lib/composio.ts (a fork that had timeout
// handling this one lacked), plus inline copies in automation-runner and
// generate-custom-probes. The 2026-08-06 fix for hung calls therefore landed
// in exactly one of the four, and automation-runner — which drives every
// scheduled Gmail parser — went five days still able to die as an uncaught
// exception. Consolidated 2026-08-11: the timeout handling lives HERE now, so
// a fix applied once is a fix applied everywhere.
//
// TIMEOUTS, and why they are not optional. An external call that hangs is not
// an error the calling code can catch. It runs until the Supabase platform's
// own wall-clock limit kills the whole invocation, surfacing as status 546
// with no stack and no log line. On a cron path that is close to invisible:
// the run simply never reports. Every call through this file is bounded, and a
// timeout comes back as an ordinary {ok:false} result the caller can handle.
//
// NO RETRIES here, on purpose. Retrying a hang doubles the wait and can push
// an otherwise-healthy invocation over the platform limit too. Retry is a
// separate decision belonging to the caller.
// =========================================================================


const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";

/** Default ceiling for any single Composio call. Well under the platform
 *  wall-clock limit so a stuck call fails fast AND catchably. */
const COMPOSIO_TIMEOUT_MS = 25000;

/** Same number, separate name: storage/S3 downloads are a distinct concern
 *  that happens to want the same ceiling. Kept apart so changing one does not
 *  silently change the other. */
const S3_FETCH_TIMEOUT_MS = 25000;

/** Where a timeout should be reported, if anywhere. Omit entirely and a
 *  timeout returns a clean failed result without writing an alert — correct
 *  for callers that already record their own failures (automation-runner logs
 *  every recipe failure to automation_run_log and Telegram). */
interface TimeoutAlertTarget {
  agencyId?: string;
  moduleReference: string;
  context: string;
}

async function writeTimeoutAlert(
  service: string,
  elapsedMs: number,
  target: TimeoutAlertTarget,
): Promise<void> {
  try {
    await insertAlert({
      agencyId: target.agencyId ?? AGENCY_ID_DEFAULT,
      alertType: "external_call_timeout",
      severity: "warning",
      title: `${service} call timed out`,
      message: `${service} call did not respond within ${elapsedMs}ms and was aborted. Context: ${target.context}`,
      moduleReference: target.moduleReference,
    });
  } catch (_e) {
    // Best-effort. Must never mask the original timeout or throw a second
    // uncaught exception on the way out.
  }
}

/**
 * fetch() with a hard time limit. Returns res:null on timeout or throw, never
 * rejects. Use this for ANY outbound call in an edge function, not just
 * Composio ones — a bare fetch() to Google, Groq or storage carries exactly
 * the same hang risk.
 */
async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
  service: string,
  context: string,
  alertTarget?: TimeoutAlertTarget,
): Promise<{ res: Response | null; timedOut: boolean; elapsedMs: number }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = Date.now();
  try {
    const res = await fetch(url, { ...init, signal: controller.signal });
    return { res, timedOut: false, elapsedMs: Date.now() - startedAt };
  } catch (e) {
    const elapsedMs = Date.now() - startedAt;
    const timedOut = e instanceof Error && e.name === "AbortError";
    if (timedOut && alertTarget) {
      await writeTimeoutAlert(service, elapsedMs, alertTarget);
    } else if (!timedOut) {
      console.error(`[${service}] fetch threw after ${elapsedMs}ms (${context}): ${e instanceof Error ? e.message : String(e)}`);
    }
    return { res: null, timedOut, elapsedMs };
  } finally {
    clearTimeout(timer);
  }
}

function unwrapComposio(text: string, httpOk: boolean, status: number): ComposioCallResult {
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = httpOk && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok
    ? null
    : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: status };
}

function composioTimeoutResult(slug: string, timedOut: boolean, elapsedMs: number): ComposioCallResult {
  return {
    ok: false,
    data: null,
    httpStatus: 0,
    error: timedOut
      ? `Composio ${slug} did not respond within ${elapsedMs}ms and was aborted`
      : `Composio ${slug} fetch failed after ${elapsedMs}ms`,
  };
}

interface ComposioCallResult {
  ok: boolean;
  data: any;
  error: string | null;
  httpStatus: number;
}

async function callComposio(opts: {
  apiKey: string;
  userId: string;
  connectedAccountId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
  /**
   * Which published set of tools to use. LEAVE THIS UNSET unless you have a
   * reason not to.
   *
   * Composio publishes its tools in dated sets. A request that does not name a
   * set gets the oldest one, which holds far fewer tools than the account
   * actually has — 51 Google Drive tools instead of 90. Anything missing from
   * that oldest set answers "Tool ... not found", which reads exactly like a
   * permission problem and is not one. Two months of Drive filing and every
   * scanned resume were lost to this, and four rounds of fixing went at the
   * wrong layer, because a tool tested by hand goes through a connection that
   * DOES name a set and therefore always worked.
   *
   * It is set per request on purpose. Naming a newer set changes the shape of
   * what comes back, and the payroll, bank statement and comp parsers all read
   * those shapes. So each caller opts in where it has been checked, rather than
   * one flip changing everything at once.
   */
  toolkitVersion?: string;
  timeoutMs?: number;
  alertTarget?: TimeoutAlertTarget;
}): Promise<ComposioCallResult> {
  const { res, timedOut, elapsedMs } = await fetchWithTimeout(
    `${COMPOSIO_BASE}/${opts.toolSlug}`,
    {
      method: "POST",
      headers: {
        "x-api-key": opts.apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        user_id: opts.userId,
        connected_account_id: opts.connectedAccountId,
        arguments: opts.toolArguments,
        ...(opts.toolkitVersion ? { version: opts.toolkitVersion } : {}),
      }),
    },
    opts.timeoutMs ?? COMPOSIO_TIMEOUT_MS,
    `composio:${opts.toolSlug}`,
    `tool=${opts.toolSlug}`,
    opts.alertTarget,
  );
  if (!res) return composioTimeoutResult(opts.toolSlug, timedOut, elapsedMs);
  return unwrapComposio(await res.text(), res.ok, res.status);
}

async function callComposioNoAuth(opts: {
  apiKey: string;
  userId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
  timeoutMs?: number;
  alertTarget?: TimeoutAlertTarget;
}): Promise<ComposioCallResult> {
  const { res, timedOut, elapsedMs } = await fetchWithTimeout(
    `${COMPOSIO_BASE}/${opts.toolSlug}`,
    {
      method: "POST",
      headers: {
        "x-api-key": opts.apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        user_id: opts.userId,
        arguments: opts.toolArguments,
      }),
    },
    opts.timeoutMs ?? COMPOSIO_TIMEOUT_MS,
    `composio:${opts.toolSlug}`,
    `tool=${opts.toolSlug} (no connected account)`,
    opts.alertTarget,
  );
  if (!res) return composioTimeoutResult(opts.toolSlug, timedOut, elapsedMs);
  return unwrapComposio(await res.text(), res.ok, res.status);
}

// ==================== generate-custom-probes/index.ts ====================
// deno-lint-ignore-file no-explicit-any
// Edge function: generate-custom-probes  (v13.0)
// framework-matches layer retired 2026-08-13 — engine (hiregauge_evaluate_candidate)
// dropped in CTS purge; facet-direct press-on system supersedes it.
//
// Changes from v12.0:
//   - Removed the hiregauge_evaluate_candidate RPC call, framework_readout
//     construction, the FRAMEWORK MATCHES block in the user message prompt,
//     the framework_matches_n output stamp, and the "Archetype probes" /
//     "Motivation probe" / "Structure fit" sections (all fed only by that
//     dropped engine) from SYSTEM_PROMPT and SECTION_PRIORITY. "Areas to
//     press on" (facet-direct) and "Validity follow-up" (reliability, read
//     directly off the candidate row) are unaffected and stay exactly as is.
//
// Changes from v11.0 (historical, retained for context):
//   - Migration F re-key (planning-authorized 2026-08-07, F.1 of the F
//     companion package). The two-hop selection this function used --
//     competency weight (hiregauge_competency_weights) -> hand-copied
//     COMPETENCY_FACET_INPUTS map -> facet -- is replaced by a single
//     facet-direct lookup against hiregauge_role_facet_weights, which is
//     already facet-level (input_name IS the facet, no map needed).
//     COMPETENCY_FACET_INPUTS is deleted entirely, along with every
//     reference to hiregauge_competency_weights in this file.
//   - Filter is weight >= 2 (this role's above-baseline facets), explicitly
//     named as such in code and comments -- never "nonzero". On this table
//     weights run roughly -1..3, zeros are meaningful (deliberately-excluded
//     facets, e.g. sincerity/fairness/greed_avoidance to avoid double-
//     counting the integrity floor), and anger can carry a negative weight.
//     "nonzero" would silently include those two very different cases.
//   - gma and sjt are ability/scenario scores, not probeable personality
//     facets, so they're excluded from the candidate pool (input_name NOT
//     IN ('gma','sjt')) the same way the old map never included them.
//   - Fallback shape unchanged: if fewer than 3 facets survive the p20/p80
//     candidate-extremes cut at weight>=2, widen to weight>=1 for that
//     candidate and log it (pressOnFallbackUsed) -- same behavior as v11.0,
//     just reading a different source table.
//   - Everything else (probe generation, budget, prompt, output shape) is
//     unchanged from v11.0.
//
// Prior header (v11.0, retained for history):
//   Changes from v10.0:
//   - Replacement for the removed Trait-triggers subsystem (TASK B2,
//     build-instructions 2026-08-06). NOT a question bank, NOT a scoring
//     layer, NOT a stored column. At request time: (1) look up which
//     facets carry above-baseline weight for this candidate's best-fit
//     role in hiregauge_role_facet_weights, (2) read live facet
//     percentiles via hiregauge_candidate_facet_percentiles (already-
//     existing, computed on read, never stored), (3) keep only facets
//     at/below p20 or at/above p80, capped to the 4 most extreme by
//     distance from p50. Surfaced to the model as follow-up context under
//     "Areas to press on" -- the fixed core question set is untouched;
//     these are additions, never substitutions (Campion, Palmer & Campion
//     1997; Levashina, Hartwell, Morgeson & Campion 2014 -- structured
//     interviews lose validity as structure erodes). p20/p80 is a
//     probe-targeting convention to bound prompt length, not a
//     psychometric threshold -- carries no validity claim.
//   - v9.0's Trait-triggers subsystem (TRAIT_IDEAL, TRAIT_BAND,
//     detectTriggers, triggerToHeader, the Final Interview manual lookup)
//     was removed in v10.0 (TASK B1) -- see that revision's header for why.


const GROQ_MODEL_FALLBACK = "openai/gpt-oss-120b";
const GROQ_ENDPOINT       = "https://api.groq.com/openai/v1/chat/completions";

// Interview time budget shipped 2026-07-17. Deep-dive = 35 min, ~3-4 min per probe → cap 10, hard max 12.
const TIME_BUDGET_MINUTES = 35;
const PROBE_COUNT_TARGET  = 10;
const PROBE_COUNT_HARD_MAX = 12;


// Priority order for which sections survive when total exceeds hard-max.
// Higher = kept first when trimming. Resume signals are ONLY answerable by this specific
// candidate about their specific claims — highest per-probe information leverage.
const SECTION_PRIORITY: Record<string, number> = {
  "Resume signals":                100,
  "Character floor verification":   90,
  "Validity follow-up":             70,
};


const json = (o: any, s = 200) => new Response(JSON.stringify(o), {
  status: s,
  headers: { "Content-Type": "application/json", ...CORS_HEADERS },
});

const supa = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);



function extractDriveFileId(url: string): string | null {
  if (!url) return null;
  const m1 = url.match(/\/file\/d\/([a-zA-Z0-9_-]{15,})/);
  if (m1) return m1[1];
  const m2 = url.match(/[?&]id=([a-zA-Z0-9_-]{15,})/);
  if (m2) return m2[1];
  return null;
}

async function composioDriveBytesToB64(composioData: any): Promise<{ ok: true; b64: string } | { ok: false; error: string }> {
  const s3url = composioData?.downloaded_file_content?.s3url ?? composioData?.file?.s3url;
  if (s3url) {
    try {
      const r = await fetch(s3url);
      if (!r.ok) return { ok: false, error: `s3url fetch HTTP ${r.status}` };
      const buf = new Uint8Array(await r.arrayBuffer());
      let bin = "";
      const CHUNK = 0x8000;
      for (let i = 0; i < buf.length; i += CHUNK) bin += String.fromCharCode(...buf.subarray(i, i + CHUNK));
      return { ok: true, b64: btoa(bin) };
    } catch (e) {
      return { ok: false, error: `s3url fetch threw: ${e instanceof Error ? e.message : String(e)}` };
    }
  }
  const inline = composioData?.file_content ?? composioData?.data;
  if (typeof inline === "string" && inline.length > 0) return { ok: true, b64: inline };
  return { ok: false, error: "no s3url and no inline bytes on composio response" };
}

async function extractPdfText(bytesB64: string): Promise<{ ok: true; text: string } | { ok: false; error: string }> {
  try {
    const bin = atob(bytesB64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const pdf = await getDocumentProxy(bytes);
    const { text } = await unpdfExtractText(pdf, { mergePages: true });
    const merged = Array.isArray(text) ? text.join("\n") : String(text ?? "");
    if (!merged.trim()) return { ok: false, error: "unpdf returned empty text (likely image-based PDF)" };
    return { ok: true, text: merged };
  } catch (e) {
    return { ok: false, error: `unpdf extraction failed: ${e instanceof Error ? e.message : String(e)}` };
  }
}

async function fetchResumeText(agencyId: string, resumeUrl: string | null, extractedText: string | null): Promise<{ text: string | null; source: string }> {
  // Prefer already-extracted text on hiring_candidates.resume_extracted_text (v8 addition — avoids re-downloading)
  if (extractedText && extractedText.trim().length > 0) {
    const capped = extractedText.length > 12000 ? extractedText.slice(0, 12000) + "\n[...truncated at 12000 chars]" : extractedText;
    return { text: capped, source: "extracted_text_column" };
  }
  if (!resumeUrl) return { text: null, source: "no_resume_url" };
  const fileId = extractDriveFileId(resumeUrl);
  if (!fileId) return { text: null, source: `unrecognized_url_shape:${resumeUrl.slice(0, 80)}` };
  const apiKey    = await getSettingOrNull(agencyId, "composio_api_key");
  const userId    = await getSettingOrNull(agencyId, "composio_user_id");
  const driveAcct = await getSettingOrNull(agencyId, "composio_googledrive_account_id");
  if (!apiKey || !userId || !driveAcct) return { text: null, source: "composio_drive_not_configured" };
  const dl = await callComposio({ apiKey, userId, connectedAccountId: driveAcct, toolSlug: "GOOGLEDRIVE_DOWNLOAD_FILE", toolArguments: { fileId } });
  if (!dl.ok) return { text: null, source: `drive_download_failed:${(dl.error || "").slice(0, 120)}` };
  const bytes = await composioDriveBytesToB64(dl.data);
  if (!bytes.ok) return { text: null, source: `bytes_unpack_failed:${bytes.error.slice(0, 120)}` };
  const ex = await extractPdfText(bytes.b64);
  if (!ex.ok) return { text: null, source: `pdf_extract_failed:${ex.error.slice(0, 120)}` };
  const capped = ex.text.length > 12000 ? ex.text.slice(0, 12000) + "\n[...truncated at 12000 chars]" : ex.text;
  return { text: capped, source: "drive_download" };
}

interface FacetFlag { facet: string; percentile: number; direction: "low" | "high"; }

// Areas-to-press-on selection: role-relevant facets at/below p20 or at/above
// p80, capped to the 4 most extreme by distance from p50. Convention for
// bounding prompt length -- not a psychometric threshold, no validity claim.
//
// MIGRATION F RE-KEY 2026-08-07: facet-direct. roleFacetWeights comes
// straight from hiregauge_role_facet_weights (input_name IS the facet --
// no COMPETENCY_FACET_INPUTS map, no two-hop lookup). Filter is
// weight >= 2 named explicitly -- this table runs roughly -1..3, zeros are
// meaningful (deliberately-excluded facets), and anger can be negative, so
// "nonzero" would silently pull in the wrong set. Fallback: if weight>=2
// gives fewer than 3 flagged facets after the p20/p80 cut, widen to
// weight>=1 for that candidate and log it (pressOnFallbackUsed) -- same
// shape as the old fallback, just reading the facet-direct table.
function selectPressOnFacets(
  roleCategory: string | null,
  roleFacetWeights: Array<{ input_name: string; weight: number }>,
  facetPercentiles: Array<{ facet: string; percentile: number | null }>
): { flagged: FacetFlag[]; fallbackUsed: boolean } {
  if (!roleCategory) return { flagged: [], fallbackUsed: false };

  const flagAtThreshold = (minWeight: number): FacetFlag[] => {
    const relevantFacets = new Set(
      roleFacetWeights
        .filter(w => Number(w.weight) >= minWeight && w.input_name !== "gma" && w.input_name !== "sjt")
        .map(w => w.input_name)
    );
    const out: FacetFlag[] = [];
    for (const fp of facetPercentiles) {
      if (fp.percentile == null) continue;
      if (!relevantFacets.has(fp.facet)) continue;
      if (fp.percentile <= 20) out.push({ facet: fp.facet, percentile: fp.percentile, direction: "low" });
      else if (fp.percentile >= 80) out.push({ facet: fp.facet, percentile: fp.percentile, direction: "high" });
    }
    out.sort((a, b) => Math.abs(b.percentile - 50) - Math.abs(a.percentile - 50));
    return out;
  };

  // weight >= 2 -- explicit, never "nonzero". See header comment.
  const atTwoPlus = flagAtThreshold(2);
  if (atTwoPlus.length >= 3) return { flagged: atTwoPlus.slice(0, 4), fallbackUsed: false };

  const atOnePlus = flagAtThreshold(1);
  return { flagged: atOnePlus.slice(0, 4), fallbackUsed: true };
}

// Post-processing: enforce hard cap by dropping lowest-priority sections/probes first.
// Never touches question/listen_for/concern content; just trims the count.
function enforceProbeCap(probes: any): { trimmed: any; trim_note: string | null } {
  if (!Array.isArray(probes?.sections)) return { trimmed: probes, trim_note: null };
  const total = probes.sections.reduce((sum: number, s: any) => sum + (Array.isArray(s?.probes) ? s.probes.length : 0), 0);
  if (total <= PROBE_COUNT_HARD_MAX) return { trimmed: probes, trim_note: null };

  const sorted = [...probes.sections].sort((a: any, b: any) => {
    const pa = SECTION_PRIORITY[a?.focus] ?? 0;
    const pb = SECTION_PRIORITY[b?.focus] ?? 0;
    return pb - pa;
  });
  const kept: any[] = [];
  let runningCount = 0;
  const originalTotal = total;
  for (const section of sorted) {
    const probesArr = Array.isArray(section?.probes) ? section.probes : [];
    const remaining = PROBE_COUNT_HARD_MAX - runningCount;
    if (remaining <= 0) break;
    if (probesArr.length <= remaining) {
      kept.push(section);
      runningCount += probesArr.length;
    } else {
      kept.push({ ...section, probes: probesArr.slice(0, remaining) });
      runningCount = PROBE_COUNT_HARD_MAX;
      break;
    }
  }
  return {
    trimmed: { ...probes, sections: kept },
    trim_note: `trimmed from ${originalTotal} to ${runningCount} probes (hard cap ${PROBE_COUNT_HARD_MAX})`,
  };
}

const SYSTEM_PROMPT = `You are the intelligence layer of Newtworks, Peter Story's State Farm agency in San Antonio, TX. Your job right now is to compile CANDIDATE-SPECIFIC interview probe questions for the hiring pipeline. Peter or a Unit Manager will use these questions during the Final Interview.

INTERVIEW STRUCTURE (fixed — you are ONLY producing the deep-dive middle):
- 5 min: rapport + "any burning questions before we start?" (not your job)
- 5 min: warm-up structured questions — same 3 every candidate (not your job)
- 35 min: DEEP DIVE PROBES ← this is what you produce
- 10 min: candidate's questions for us (not your job)
- 5 min: close + next steps (not your job)

HARD CONSTRAINTS on your output:
- Target ${PROBE_COUNT_TARGET} total probes across all sections. Absolute max ${PROBE_COUNT_HARD_MAX}.
- Every probe averages 3-4 min to ask + probe. 12 probes = 36-48 min. Ten is the sweet spot.
- Never produce a generic probe just to fill a slot. If the data doesn't warrant a probe, don't invent one.

Framework context:
- The agency uses HireGauge (Story Agency calibration). Two personality traits with ideal ranges are still on file for every candidate: assertiveness and compassion. Reliability is a validity band indicator (values: very high / high / moderate / low / very low). Do not ask for, refer to, or reason about any other trait score — no other trait data exists on the record.
- Character floor is non-negotiable at 7/10 across Honesty, Concern for Others, Hard Work Ethic, Personal Responsibility (measured in interview scorecards).
- Every hire participates in selling — even reception/retention seats. Every team member carries image-bearer dignity (Genesis 1:27) — probes should be direct but never demeaning.

Rules for the probes you produce:
1. Every probe must be traceable to a specific signal in the data you receive. Never invent generic screening questions. If the data doesn't support a section, omit it.
2. Group probes by focus. Priority order when picking what to include (fill from top down, stop at ${PROBE_COUNT_TARGET}-${PROBE_COUNT_HARD_MAX}):
   1. "Resume signals" — specific claims on the resume that need verification (biggest-account, promotion claims, gaps, self-superiority language). Highest per-probe leverage — only this candidate can answer these. Target 3-4.
   2. "Character floor verification" — only fire for character areas the framework flagged concerning. If nothing is concerning, skip this section entirely. Target 0-3.
   3. "Areas to press on" — see the AREAS TO PRESS ON block in the user message, if present. These are FOLLOW-UP probes only, appended after the fixed core question set — never a substitute for it. One probe per listed facet, up to the number listed. If the block is absent, skip this section entirely — do not invent one. Target 0-4.
   4. "Validity follow-up" — moderate/low reliability. Target 0-2.
3. Each probe object has: question (the exact question to ask), listen_for (what a genuine, encouraging answer sounds like), concern (what would signal a red flag or watch), source (a short tag pointing at the signal — e.g. "trait:assertiveness=32(low)", "validity:reliability=moderate", "resume:self-superiority-language"). ALL FOUR FIELDS ARE REQUIRED on every probe.
4. Do NOT include Title VII protected-class questions (race, religion, national origin, marital status, family status, disability, age). This applies to EVERY section, including Areas to press on — a facet flag is never grounds to ask about a protected characteristic, and none of the facets in that block relate to one.
5. Do NOT include SF compliance-restricted topics (specific product names, prices, internal SF processes like Scorecard/AIPP).
6. If resume text IS provided: Resume signals section MUST be included AND MUST be the top-priority section. Reference the exact resume phrasing when you can. Never collapse the entire output down to only resume signals — trait triggers and character floor concerns still need to be probed.
7. If resume text is unavailable, do NOT invent resume-specific probes. Note it in "notes" instead.
8. DO NOT include warm-up questions ("tell me about your last role", "why insurance", "why our agency"). Those are asked before the deep-dive. Your output is the deep-dive only.

AREAS TO PRESS ON — how to use (if the block appears in the user message):
- Each entry is a role-relevant facet where this candidate scored at or below the 20th percentile or at or above the 80th percentile against typical adults, in a direction the specific role weights.
- This is NOT a diagnosis and NOT a red flag by itself — write a genuinely curious behavioral probe, not a gotcha. Low or high just means "worth understanding this candidate's specific pattern here."
- One probe per listed facet. Do not invent extra facets. Do not speculate about facets not listed.
- source tag: "facet:<name>=<percentile>th(<low/high>)".
- These probes are follow-ups appended AFTER the fixed core question set — never a replacement for Resume signals, Character floor, or any other section.

Style directives (agency voice):
- Direct, first-person plural: "We'd like to understand...", "Walk us through...", "Tell us about a time when..."
- Behavioral, not hypothetical: "Describe a specific instance where..." not "How would you handle..."
- Never HR-corporate filler. Bad: "At State Farm, we value teamwork — how do you demonstrate that?" Good: "Give us a recent example where a teammate got credit that could have been yours."
- Short questions. If the instinct is to compound-question, split into two probes.
- listen_for describes what a genuine answer sounds like — specifics vs. platitudes, ownership vs. blame, presence vs. rehearsed.
- concern names the specific red flag, not "poor answer".

Output requirements:
- Return ONLY valid JSON. No markdown fences, no preamble, no trailing prose.
- Match this exact shape:
{
  "sections": [
    { "focus": "string", "probes": [ { "question": "string", "listen_for": "string", "concern": "string", "source": "string" } ] }
  ],
  "notes": "optional string — caveats about generation, e.g. 'resume text not available so no resume-signal probes included'"
}`;

async function generateProbes(context: any, groqKey: string, model: string): Promise<any> {
  const pressOnBlock = context.press_on_facets.length === 0
    ? ""
    : `\n\nAREAS TO PRESS ON (role-relevant facets at/below p20 or at/above p80 vs typical adults):\n${
        context.press_on_facets.map((f: FacetFlag) => `  - ${f.facet}: ${f.percentile}th percentile (${f.direction})`).join("\n")
      }`;

  const userMsg = `CANDIDATE: ${context.candidate_name}
POSITION APPLIED FOR: ${context.position || "(not specified)"}

VALIDITY (band label; framework validity_rule matches will fire if concerning):
  reliability: ${context.a.reliability ?? "—"}

CLAUDE RESUME SUMMARY (from intake analysis):
${context.a.claude_summary || "(no resume summary on file)"}${pressOnBlock}

RESUME TEXT: ${context.resume_text ? context.resume_text : "(not available — do not fabricate resume-specific probes, note this in output.notes)"}

Generate the JSON now. Target ${PROBE_COUNT_TARGET} total probes, hard cap ${PROBE_COUNT_HARD_MAX}. Return only the JSON object, nothing else.`;

  const resp = await fetch(GROQ_ENDPOINT, {
    method: "POST",
    headers: { "Authorization": `Bearer ${groqKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model, temperature: 0.4, max_tokens: 2500,
      messages: [{ role: "system", content: SYSTEM_PROMPT }, { role: "user", content: userMsg }],
      response_format: { type: "json_object" },
    }),
  });
  if (!resp.ok) { const txt = await resp.text(); throw new Error(`Groq API ${resp.status}: ${txt.slice(0, 500)}`); }
  const data = await resp.json();
  const content = data?.choices?.[0]?.message?.content;
  if (!content) throw new Error("Groq returned no content");
  let parsed: any;
  try { parsed = JSON.parse(content); }
  catch (e) { throw new Error("Groq output not valid JSON: " + (e as Error).message); }
  if (!Array.isArray(parsed?.sections)) throw new Error("Groq output missing 'sections' array");
  return parsed;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST")    return json({ error: "POST only" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const assessmentId = body?.assessment_id;
    if (!assessmentId || typeof assessmentId !== "string") return json({ error: "assessment_id required (string)" }, 400);
    const { data: a, error: aErr } = await supa.from("hiring_candidates").select("*").eq("id", assessmentId).maybeSingle();
    if (aErr) return json({ error: "load candidate: " + aErr.message }, 500);
    if (!a)   return json({ error: "candidate not found" }, 404);
    const resumeFetch = await fetchResumeText(a.agency_id, a.resume_url, a.resume_extracted_text);

    // MIGRATION F re-key: facet-direct "Areas to press on". best-fit role ->
    // hiregauge_role_facet_weights (weight>=2, facet-level already) ->
    // live facet percentiles -> extreme ones. No COMPETENCY_FACET_INPUTS map.
    let pressOnFacets: FacetFlag[] = [];
    let pressOnFallbackUsed = false;
    let bestRoleForFacets: string | null = null;
    try {
      const { data: bestFit } = await supa.rpc("assessment_best_fit_role", { p_assessment_id: assessmentId });
      bestRoleForFacets = (Array.isArray(bestFit) && bestFit[0]?.best_role) || null;
      if (bestRoleForFacets) {
        const [{ data: roleFacetWeights }, { data: percentiles }] = await Promise.all([
          supa.from("hiregauge_role_facet_weights").select("input_name, weight").eq("role_category", bestRoleForFacets),
          supa.rpc("hiregauge_candidate_facet_percentiles", { p_candidate_id: assessmentId }),
        ]);
        const selection = selectPressOnFacets(bestRoleForFacets, roleFacetWeights || [], percentiles || []);
        pressOnFacets = selection.flagged;
        pressOnFallbackUsed = selection.fallbackUsed;
      }
    } catch (e) {
      console.warn("press-on facet selection failed (non-fatal):", e instanceof Error ? e.message : String(e));
    }

    const context = {
      candidate_name: [a.first_name, a.last_name].filter(Boolean).join(" ") || a.candidate_name || "Candidate",
      position: a.position,
      resume_text: resumeFetch.text, a, press_on_facets: pressOnFacets,
    };
    const groqKey = await getSettingOrNull(a.agency_id, "groq_api_key");
    if (!groqKey) return json({ error: "settings.groq_api_key missing for agency" }, 500);
    const model = (await getSettingOrNull(a.agency_id, "groq_model_default")) || GROQ_MODEL_FALLBACK;
    const raw = await generateProbes(context, groqKey, model);
    const capped = enforceProbeCap(raw);
    const probes = capped.trimmed;

    // Stamp metadata
    probes.version              = 13.0;
    probes.model                = model;
    probes.resume_analyzed      = Boolean(context.resume_text);
    probes.resume_source        = resumeFetch.source;
    probes.resume_length_chars  = context.resume_text?.length ?? 0;
    probes.time_budget_minutes  = TIME_BUDGET_MINUTES;
    probes.probe_count_target   = PROBE_COUNT_TARGET;
    probes.probe_count_hard_max = PROBE_COUNT_HARD_MAX;
    probes.probes_total_count   = (probes.sections || []).reduce((s: number, sec: any) => s + (Array.isArray(sec?.probes) ? sec.probes.length : 0), 0);
    // Log which facets fired so the same probe set is reproducible at review time.
    probes.press_on_role        = bestRoleForFacets;
    probes.press_on_facets      = pressOnFacets;
    probes.press_on_fallback_used = pressOnFallbackUsed;
    if (capped.trim_note) probes.trim_note = capped.trim_note;
    const nowIso = new Date().toISOString();
    const { error: uErr } = await supa.from("hiring_candidates").update({ custom_probes: probes, custom_probes_generated_at: nowIso }).eq("id", assessmentId);
    if (uErr) return json({ error: "persist: " + uErr.message }, 500);
    return json({ ok: true, custom_probes: probes, generated_at: nowIso });
  } catch (err: any) {
    console.error("generate-custom-probes error:", err);
    return json({ error: err?.message || String(err) }, 500);
  }
});
