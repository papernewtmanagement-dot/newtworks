// =========================================================================
// gbp-review-checker
// =========================================================================
// v3 (2026-08-21): Self-contained single file; this file IS what is deployed
// (dist/gbp-review-checker.bundle.ts carries the identical bytes for the
// deploy pipeline). Runs HOURLY. Pulls the 5 relevance-ranked reviews Google
// Places Details is willing to show — NOT the 5 most recent; Google ranks
// that set by its own relevance signal, so a brand-new review usually never
// appears in it. Because of that cap the function also runs a rating-count
// watch: it tracks userRatingCount (settings key gbp_last_known_rating_count)
// and when the total rises without a matching readable review it alerts +
// pings the Paper Newt Management Telegram group tagging Alvi to reply by
// hand at business.google.com > Reviews. Anything new that IS readable gets a
// Groq-drafted compliance-guardrailed reply, a tasks row, and a Telegram
// message with the paste-ready draft. Rows stuck at draft_failed are retried
// automatically (3 per hourly run; redraft_failed:true retries all).
// Durable fix on file: Google Business Profile API access (full newest-first
// review list + programmatic reply posting) — see open_questions.
//
// Invoked by pg_cron via dispatch_gbp_review_checker (automation-runner's
// INTERNAL/dispatch_ branch does a direct fetch to /functions/v1/gbp-
// review-checker). See op-rule "Newtworks dispatch_* recipe convention".
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const sb: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const AGENCY_ID_DEFAULT = "126794dd-25ff-47d2-a436-724499733365";

async function getSetting(agencyId: string, key: string): Promise<string | null> {
  const { data, error } = await sb.from("settings").select("setting_value").eq("agency_id", agencyId).eq("setting_key", key).maybeSingle();
  if (error) throw new Error(`settings read failed for agency ${agencyId} key ${key}: ${error.message}`);
  return data?.setting_value ?? null;
}

async function getSettingOrNull(agencyId: string, key: string): Promise<string | null> {
  try {
    const { data } = await sb.from("settings").select("setting_value").eq("agency_id", agencyId).eq("setting_key", key).maybeSingle();
    return (data?.setting_value as string | null) ?? null;
  } catch (_e) { return null; }
}

async function upsertSetting(agencyId: string, key: string, value: string): Promise<void> {
  const existing = await getSettingOrNull(agencyId, key);
  if (existing === null) {
    const { error } = await sb.from("settings").insert({ agency_id: agencyId, setting_key: key, setting_value: value });
    if (error) console.error(`upsertSetting insert failed (${key}): ${error.message}`);
  } else {
    const { error } = await sb.from("settings").update({ setting_value: value }).eq("agency_id", agencyId).eq("setting_key", key);
    if (error) console.error(`upsertSetting update failed (${key}): ${error.message}`);
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), { status, headers: { "Content-Type": "application/json" } });
}

async function insertAlert(opts: { agencyId: string; alertType: string; severity: string; title: string; message: string; moduleReference?: string; relatedId?: string | null; }): Promise<{ ok: boolean; error: string | null }> {
  const row: Record<string, unknown> = { agency_id: opts.agencyId, alert_type: opts.alertType, severity: opts.severity, title: opts.title, message: opts.message, is_read: false, is_resolved: false };
  if (opts.moduleReference != null) row.module_reference = opts.moduleReference;
  if (opts.relatedId != null) row.related_id = opts.relatedId;
  const { error } = await sb.from("alerts").insert(row);
  if (error) { console.error(`insertAlert failed (${opts.alertType}): ${error.message}`); return { ok: false, error: error.message }; }
  return { ok: true, error: null };
}

const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";
const COMPOSIO_TIMEOUT_MS = 25000;

interface TimeoutAlertTarget { agencyId?: string; moduleReference: string; context: string; }

async function writeTimeoutAlert(service: string, elapsedMs: number, target: TimeoutAlertTarget): Promise<void> {
  try {
    await insertAlert({ agencyId: target.agencyId ?? AGENCY_ID_DEFAULT, alertType: "external_call_timeout", severity: "warning", title: `${service} call timed out`, message: `${service} call did not respond within ${elapsedMs}ms and was aborted. Context: ${target.context}`, moduleReference: target.moduleReference });
  } catch (_e) { /* best-effort */ }
}

async function fetchWithTimeout(url: string, init: RequestInit, timeoutMs: number, service: string, context: string, alertTarget?: TimeoutAlertTarget): Promise<{ res: Response | null; timedOut: boolean; elapsedMs: number }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = Date.now();
  try {
    const res = await fetch(url, { ...init, signal: controller.signal });
    return { res, timedOut: false, elapsedMs: Date.now() - startedAt };
  } catch (e) {
    const elapsedMs = Date.now() - startedAt;
    const timedOut = e instanceof Error && e.name === "AbortError";
    if (timedOut && alertTarget) { await writeTimeoutAlert(service, elapsedMs, alertTarget); }
    else if (!timedOut) { console.error(`[${service}] fetch threw after ${elapsedMs}ms (${context}): ${e instanceof Error ? e.message : String(e)}`); }
    return { res: null, timedOut, elapsedMs };
  } finally { clearTimeout(timer); }
}

interface ComposioCallResult { ok: boolean; data: any; error: string | null; httpStatus: number; }

function unwrapComposio(text: string, httpOk: boolean, status: number): ComposioCallResult {
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = httpOk && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok ? null : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: status };
}

function composioTimeoutResult(slug: string, timedOut: boolean, elapsedMs: number): ComposioCallResult {
  return { ok: false, data: null, httpStatus: 0, error: timedOut ? `Composio ${slug} did not respond within ${elapsedMs}ms and was aborted` : `Composio ${slug} fetch failed after ${elapsedMs}ms` };
}

async function callComposio(opts: { apiKey: string; userId: string; connectedAccountId: string; toolSlug: string; toolArguments: Record<string, any>; toolkitVersion?: string; timeoutMs?: number; alertTarget?: TimeoutAlertTarget; }): Promise<ComposioCallResult> {
  const { res, timedOut, elapsedMs } = await fetchWithTimeout(
    `${COMPOSIO_BASE}/${opts.toolSlug}`,
    { method: "POST", headers: { "x-api-key": opts.apiKey, "Content-Type": "application/json" }, body: JSON.stringify({ user_id: opts.userId, connected_account_id: opts.connectedAccountId, arguments: opts.toolArguments, ...(opts.toolkitVersion ? { version: opts.toolkitVersion } : {}) }) },
    opts.timeoutMs ?? COMPOSIO_TIMEOUT_MS, `composio:${opts.toolSlug}`, `tool=${opts.toolSlug}`, opts.alertTarget,
  );
  if (!res) return composioTimeoutResult(opts.toolSlug, timedOut, elapsedMs);
  return unwrapComposio(await res.text(), res.ok, res.status);
}

async function requireSharedSecret(agencyId: string, provided: string | undefined | null): Promise<Response | null> {
  if (!provided) return jsonResponse({ ok: false, error: "missing shared_secret" }, 401);
  const expected = await getSettingOrNull(agencyId, "automation_runner_cron_secret");
  if (!expected || provided !== expected) return jsonResponse({ ok: false, error: "unauthorized" }, 401);
  return null;
}

async function sendTelegram(botToken: string, chatId: string, html: string): Promise<void> {
  try {
    await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ chat_id: chatId, text: html, parse_mode: "HTML", disable_web_page_preview: true }) });
  } catch (e) { console.error(`Telegram send failed: ${(e as Error).message}`); }
}

function tgEscape(s: string): string { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

async function sendTelegramReviewAlert(opts: { botToken: string; chatId: string; alviTelegramUserId: number | null; authorName: string; rating: number | null; reviewText: string; draftedResponse: string; }): Promise<void> {
  const stars = opts.rating != null ? "\u2605".repeat(Math.max(0, Math.min(5, Math.round(opts.rating)))) : "";
  const tagHtml = opts.alviTelegramUserId ? `<a href="tg://user?id=${opts.alviTelegramUserId}">Alvi</a>` : "Alvi";
  const text = `\uD83C\uDD95 <b>New Google review</b> \u2014 ${tgEscape(opts.authorName)} (${stars})\n\n"${tgEscape(opts.reviewText).slice(0, 400)}"\n\n<b>Drafted reply</b> (paste at business.google.com &gt; Reviews):\n${tgEscape(opts.draftedResponse)}\n\n${tagHtml} \u2014 can you post this one?`;
  await sendTelegram(opts.botToken, opts.chatId, text);
}

// -------------------------------------------------------------------------
// Rating-count watch
// -------------------------------------------------------------------------
// The Places Details endpoint returns at most 5 reviews chosen by Google's
// relevance ranking, NOT by recency, so a brand-new review usually never
// appears in the set this function can read. userRatingCount, however, is the
// listing's true total and moves the moment any review or star rating lands.
// This watch keeps the last seen total in settings
// (gbp_last_known_rating_count); when the total rises without a matching new
// review in the readable set, it pings the team to reply by hand and writes an
// alert — turning structural blindness into a bounded delay with a human
// pointer. Removed reviews (count drops) just resync silently.
const RATING_COUNT_KEY = "gbp_last_known_rating_count";

async function ratingCountWatch(opts: { agencyId: string; totalRatingCount: number | null; newInserted: number; botToken: string | null; chatId: string | null; alviTelegramUserId: number | null; }): Promise<{ baseline_seeded: boolean; missed: number }> {
  const { agencyId, totalRatingCount, newInserted } = opts;
  if (totalRatingCount == null) return { baseline_seeded: false, missed: 0 };
  const storedRaw = await getSettingOrNull(agencyId, RATING_COUNT_KEY);
  const stored = storedRaw != null ? parseInt(storedRaw, 10) : null;
  if (stored == null || Number.isNaN(stored)) {
    await upsertSetting(agencyId, RATING_COUNT_KEY, String(totalRatingCount));
    return { baseline_seeded: true, missed: 0 };
  }
  if (totalRatingCount === stored) return { baseline_seeded: false, missed: 0 };
  await upsertSetting(agencyId, RATING_COUNT_KEY, String(totalRatingCount));
  const missed = totalRatingCount - stored - newInserted;
  if (missed <= 0) return { baseline_seeded: false, missed: 0 };

  await insertAlert({
    agencyId,
    alertType: "gbp_review_not_retrievable",
    severity: "warning",
    title: `Google shows ${missed} new review(s) the feed cannot retrieve`,
    message: `The listing's total rating count rose from ${stored} to ${totalRatingCount}, but the readable review set (5 relevance-ranked reviews from Places Details) did not surface ${missed} of them. Someone needs to reply manually at business.google.com > Reviews. Durable fix: Google Business Profile API access (full newest-first review list + programmatic replies).`,
    moduleReference: "gbp_reviews",
  });

  if (opts.botToken && opts.chatId) {
    const tagHtml = opts.alviTelegramUserId ? `<a href="tg://user?id=${opts.alviTelegramUserId}">Alvi</a>` : "Alvi";
    const plural = missed === 1 ? "review" : "reviews";
    await sendTelegram(opts.botToken, opts.chatId, `\u2B50 <b>${missed} new Google ${plural}</b> just landed that the automated feed can't pull (Google only shows us 5 "most relevant").\n\n${tagHtml} \u2014 can you open business.google.com &gt; Reviews, sort by newest, and reply to the ${missed === 1 ? "newest one" : `newest ${missed}`}? Keep it warm and specific; no product names, no superlatives.`);
  }
  return { baseline_seeded: false, missed };
}

const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions";
const LLM_MODEL_FALLBACK = "openai/gpt-oss-120b";
const PLACE_ID = "ChIJn5BEWaWHXIYR-u4V6qmytzM";

// gpt-oss-120b is a reasoning model: it spends output tokens on an internal
// reasoning pass BEFORE emitting the JSON body. With max_tokens=300 the budget
// was consumed by reasoning and the JSON never closed, so Groq rejected every
// single call with json_validate_failed and an empty generation. Verified
// reproducible 2026-08-21 against the live prompt. Keep the ceiling high and the
// reasoning effort low; do not lower GROQ_MAX_TOKENS below ~800.
const GROQ_MAX_TOKENS = 1200;
const GROQ_REASONING_EFFORT = "low";

const SYSTEM_PROMPT = `You write Google Business Profile owner-reply responses for an insurance agency (Peter Story State Farm, San Antonio TX).

FORMULA — every response, 2-4 sentences, hits these once each, naturally:
1. Reviewer's first name
2. One specific detail from THEIR review (product, teammate, situation)
3. Business/team mentioned once ("our team", not always the business name)
4. Vary sentence structure and opening phrase every time — you will be shown the last several openings used; NEVER repeat one of them or anything structurally similar.

HARD COMPLIANCE RULES (State Farm agent's agreement — violating any of these is a real compliance issue, not a style note):
- NEVER use: "expert", "specialist", "advisor", "consultant", "fully licensed"
- NEVER use superlatives or absolutes: "best", "always", "guaranteed", "#1", "top rated"
- NEVER mention product names, prices, premiums, or "save you money" / "save money"
- NEVER mention investments, banking, or securities (this profile is insurance-only)
- NEVER use internal State Farm program language
- Keep it warm but not effusive. Sound like a real person replied, not a template.

For 1-3 star reviews: acknowledge the experience without admitting to specific facts, do not reference any account/policy specifics, invite them to call the office directly, keep it SHORT (under 40 words), no defensiveness.

Return JSON only: {"response_text": "..."}`;

async function callGroq(agencyId: string, groqApiKey: string, userContent: string): Promise<{ ok: boolean; text: string | null; error: string | null }> {
  const model = (await getSetting(agencyId, "groq_model_default").catch(() => null)) || LLM_MODEL_FALLBACK;
  const body = { model, messages: [{ role: "system", content: SYSTEM_PROMPT }, { role: "user", content: userContent }], temperature: 0.7, max_tokens: GROQ_MAX_TOKENS, reasoning_effort: GROQ_REASONING_EFFORT, response_format: { type: "json_object" } };
  const res = await fetch(GROQ_API_URL, { method: "POST", headers: { "Authorization": `Bearer ${groqApiKey}`, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  const raw = await res.text();
  if (!res.ok) return { ok: false, text: null, error: `Groq HTTP ${res.status}: ${raw.slice(0, 300)}` };
  try {
    const parsed = JSON.parse(raw);
    const content = parsed?.choices?.[0]?.message?.content;
    if (!content) return { ok: false, text: null, error: "Groq returned empty content" };
    const extracted = JSON.parse(content);
    return { ok: true, text: extracted.response_text ?? null, error: null };
  } catch (e) { return { ok: false, text: null, error: `Groq parse failure: ${(e as Error).message}` }; }
}

// Re-draft rows stuck at draft_failed. On success the row is completed the same
// way a fresh review would be: draft stored, task created, Telegram sent —
// recovery of the normal flow, not a quieter version of it. Stops early on a
// Groq 429 so a capped day is one wasted call, not several.
async function redraftFailedRows(opts: { agencyId: string; groqApiKey: string; recentOpenings: string[]; limit: number; botToken: string | null; chatId: string | null; alviTelegramUserId: number | null; }): Promise<any[]> {
  const { data: failedRows } = await sb.from("gbp_review_tracker").select("id, author_display_name, rating, review_text").eq("agency_id", opts.agencyId).eq("status", "draft_failed").order("created_at", { ascending: true }).limit(opts.limit);
  const out: any[] = [];
  for (const row of failedRows ?? []) {
    const authorName = row.author_display_name ?? "there";
    const userContent = JSON.stringify({ reviewer_first_name: authorName.split(" ")[0], rating: row.rating, review_text: row.review_text ?? "", recent_openings_to_avoid: opts.recentOpenings });
    const g = await callGroq(opts.agencyId, opts.groqApiKey, userContent);
    if (g.ok && g.text) {
      let taskId: string | null = null;
      const { data: task, error: taskErr } = await sb.from("tasks").insert({ agency_id: opts.agencyId, title: `New Google review from ${authorName} (${row.rating}\u2605) \u2014 response drafted`, description: `Review: "${row.review_text ?? ""}"\n\nDrafted response (ready to paste at business.google.com > Reviews):\n\n${g.text}`, task_category: "marketing", task_type: "review_response", priority: (row.rating ?? 5) <= 3 ? "high" : "medium", status: "open", created_by: "gbp_review_checker" }).select("id").single();
      if (!taskErr) taskId = task?.id ?? null;
      await sb.from("gbp_review_tracker").update({ drafted_response: g.text, status: "drafted", task_id: taskId }).eq("id", row.id);
      if (opts.botToken && opts.chatId) {
        await sendTelegramReviewAlert({ botToken: opts.botToken, chatId: opts.chatId, alviTelegramUserId: opts.alviTelegramUserId, authorName, rating: row.rating, reviewText: row.review_text ?? "", draftedResponse: g.text });
      }
      opts.recentOpenings.unshift(g.text.split(" ").slice(0, 5).join(" "));
      out.push({ id: row.id, author: authorName, ok: true, task_id: taskId });
    } else {
      out.push({ id: row.id, author: authorName, ok: false, error: g.error });
      if ((g.error ?? "").includes("429")) break; // capped — stop hammering
    }
  }
  return out;
}

Deno.serve(async (req: Request) => {
  let body: any = {};
  try { body = await req.json(); } catch { /* cron dispatch may send empty body */ }
  const agencyId = body.agency_id || AGENCY_ID_DEFAULT;

  const denied = await requireSharedSecret(agencyId, body.shared_secret);
  if (denied) return denied;

  const apiKey = await getSetting(agencyId, "composio_api_key");
  const userId = await getSetting(agencyId, "composio_user_id");
  const mapsAccountId = await getSetting(agencyId, "composio_google_maps_account_id");
  const groqApiKey = await getSetting(agencyId, "groq_api_key");
  const telegramBotToken = await getSetting(agencyId, "telegram_bot_token");
  const telegramChatId = await getSetting(agencyId, "paper_newt_management_group_chat_id");
  const alviTelegramUserIdRaw = await getSetting(agencyId, "marie_telegram_user_id");
  const alviTelegramUserId = alviTelegramUserIdRaw ? parseInt(alviTelegramUserIdRaw, 10) : null;
  if (!apiKey || !userId || !mapsAccountId) return jsonResponse({ ok: false, error: "missing Composio Google Maps credentials in settings" }, 500);
  if (!groqApiKey) return jsonResponse({ ok: false, error: "missing groq_api_key in settings" }, 500);

  const { data: recentDrafts } = await sb.from("gbp_review_tracker").select("drafted_response").eq("agency_id", agencyId).not("drafted_response", "is", null).order("created_at", { ascending: false }).limit(10);
  const recentOpenings = (recentDrafts ?? []).map((r: any) => (r.drafted_response as string).split(" ").slice(0, 5).join(" ")).filter(Boolean);

  // Explicit maintenance mode: re-draft ALL rows stuck at draft_failed.
  if (body.redraft_failed === true) {
    const redrafted = await redraftFailedRows({ agencyId, groqApiKey, recentOpenings, limit: 25, botToken: telegramBotToken, chatId: telegramChatId, alviTelegramUserId });
    return jsonResponse({ ok: true, mode: "redraft_failed", attempted: redrafted.length, results: redrafted });
  }

  // Hourly self-heal: quietly retry up to 3 stuck rows each run so a capped or
  // flaky drafting day converges on its own instead of waiting for maintenance.
  const autoRedrafted = await redraftFailedRows({ agencyId, groqApiKey, recentOpenings, limit: 3, botToken: telegramBotToken, chatId: telegramChatId, alviTelegramUserId });

  const composioResult = await callComposio({ apiKey, userId, connectedAccountId: mapsAccountId, toolSlug: "GOOGLE_MAPS_GET_PLACE_DETAILS", toolArguments: { name: `places/${PLACE_ID}`, fieldMask: "id,displayName,rating,userRatingCount,reviews" }, toolkitVersion: "latest" });
  if (!composioResult.ok) return jsonResponse({ ok: false, error: `Google Maps call failed: ${composioResult.error}` }, 500);

  const reviews: any[] = composioResult.data?.reviews ?? [];
  const totalRatingCount: number | null = composioResult.data?.userRatingCount ?? null;

  if (reviews.length === 0) {
    const watch = await ratingCountWatch({ agencyId, totalRatingCount, newInserted: 0, botToken: telegramBotToken, chatId: telegramChatId, alviTelegramUserId });
    return jsonResponse({ ok: true, new_reviews: 0, fetched: 0, total_rating_count: totalRatingCount, count_watch: watch, auto_redrafted: autoRedrafted, source_limit_note: "Places Details returned no reviews" });
  }

  const results: any[] = [];
  let alreadyKnown = 0;

  for (const rev of reviews) {
    const googleReviewName: string = rev.name;
    const authorName: string = rev.authorAttribution?.displayName ?? "there";
    const rating: number = rev.rating ?? null;
    const text: string = rev.text?.text ?? rev.originalText?.text ?? "";
    const publishTime: string | null = rev.publishTime ?? null;

    const { data: existing } = await sb.from("gbp_review_tracker").select("id").eq("place_id", PLACE_ID).eq("google_review_name", googleReviewName).maybeSingle();
    if (existing) { alreadyKnown++; continue; }

    const userContent = JSON.stringify({ reviewer_first_name: authorName.split(" ")[0], rating, review_text: text, recent_openings_to_avoid: recentOpenings });
    const groqResult = await callGroq(agencyId, groqApiKey, userContent);
    const draftedResponse = groqResult.ok ? groqResult.text : null;

    let taskId: string | null = null;
    if (draftedResponse) {
      const { data: task, error: taskErr } = await sb.from("tasks").insert({ agency_id: agencyId, title: `New Google review from ${authorName} (${rating}\u2605) \u2014 response drafted`, description: `Review: "${text}"\n\nDrafted response (ready to paste at business.google.com > Reviews):\n\n${draftedResponse}`, task_category: "marketing", task_type: "review_response", priority: rating <= 3 ? "high" : "medium", status: "open", created_by: "gbp_review_checker" }).select("id").single();
      if (!taskErr) taskId = task?.id ?? null;

      if (telegramBotToken && telegramChatId) {
        await sendTelegramReviewAlert({ botToken: telegramBotToken, chatId: telegramChatId, alviTelegramUserId, authorName, rating, reviewText: text, draftedResponse });
      }
    }

    const { data: inserted } = await sb.from("gbp_review_tracker").insert({ agency_id: agencyId, place_id: PLACE_ID, google_review_name: googleReviewName, author_display_name: authorName, rating, review_text: text, publish_time: publishTime, drafted_response: draftedResponse, task_id: taskId, status: draftedResponse ? "drafted" : "draft_failed" }).select("id").maybeSingle();

    // A review that lands but never gets a draft produces no task and no
    // Telegram message. Without this alert that failure is completely silent —
    // which is exactly how five reviews sat undrafted and unnoticed.
    if (!draftedResponse) {
      await insertAlert({
        agencyId,
        alertType: "gbp_review_draft_failed",
        severity: "warning",
        title: `Google review reply could not be drafted (${authorName})`,
        message: `A new Google review was captured but the reply draft failed, so no task and no Telegram message were created. Reason: ${groqResult.error ?? "unknown"}. Review is stored in gbp_review_tracker with status draft_failed; the hourly run retries it automatically.`,
        moduleReference: "gbp_reviews",
        relatedId: inserted?.id ?? null,
      });
    }

    if (draftedResponse) recentOpenings.unshift(draftedResponse.split(" ").slice(0, 5).join(" "));
    results.push({ author: authorName, rating, drafted: !!draftedResponse, task_id: taskId, error: groqResult.ok ? null : groqResult.error });
  }

  const watch = await ratingCountWatch({ agencyId, totalRatingCount, newInserted: results.length, botToken: telegramBotToken, chatId: telegramChatId, alviTelegramUserId });

  return jsonResponse({
    ok: true,
    new_reviews: results.length,
    fetched: reviews.length,
    already_known: alreadyKnown,
    total_rating_count: totalRatingCount,
    count_watch: watch,
    auto_redrafted: autoRedrafted,
    source_limit_note: "Places Details caps at 5 relevance-ranked reviews; the rating-count watch covers what the feed cannot show",
    results,
  });
});
