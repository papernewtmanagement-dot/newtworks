// =============================================================================
// gbp-review-checker — Google review watcher + reply drafter (v10, 2026-08-21)
// =============================================================================
// Watches the agency's Google Business Profile reviews, drafts compliant owner
// replies, and routes them to the team (task + Telegram tagging Alvi) for
// posting. Hourly via automation runner (dispatch_gbp_review_checker).
//
// WHY THIS ARCHITECTURE (hard-won 2026-08-21 — read before "simplifying"):
//   Google gives an agency NO free programmatic feed of its newest reviews.
//   - Places Details (via Composio GOOGLE_MAPS_GET_PLACE_DETAILS): max 5
//     reviews, RELEVANCE-ranked, never newest. New reviews usually invisible.
//   - Scraping Maps internal endpoints: 403 app-level from datacenter IPs on
//     every variant tried; older endpoints 404 retired. Do not retry.
//   - Google Business Profile API: the durable fix (full newest-first list +
//     posting replies programmatically) — form-gated approval, pending Peter.
//
// So v8+ reads reviews from OUR OWN microsite instead (Peter's call):
//   timberwoodparkinsurance.com/reviews (State Farm / Mirus mx-static) renders
//   the ~25 NEWEST reviews server-side with author, date, stars, full text,
//   AND whether the owner reply is posted ("We responded"). Recency-ordered
//   and answered-aware — everything Places can't do. Its data lags Google by a
//   few days (corporate sync), so the Places rating-count watch stays on as
//   the same-hour tripwire for brand-new reviews.
//
// RUN ORDER (matters):
//   1. micrositePass  — flip answered rows to responded (+complete tasks),
//                       draft replies for unanswered ones (task+Telegram).
//   2. auto-retry     — re-draft up to 3 draft_failed rows (self-heal).
//                       Runs AFTER (1) so already-answered rows don't burn
//                       Groq tokens. Stops on 429.
//   3. Places pass    — 5 relevance reviews (cross-source deduped) + live
//                       userRatingCount for the count watch.
//
// LANDMINES (each one cost real debugging time):
//   - Groq gpt-oss-120b is a reasoning model: max_tokens < ~800 = reasoning
//     eats the budget, JSON never emitted, every call fails. Keep 1200/low.
//   - Groq free tier: 200k tokens/day shared across ALL automations. A capped
//     day mimics a broken prompt (429 TPD). Retry converges hourly.
//   - tasks.task_type CHECK allows only epic/story/task. "review_response"
//     failed silently forever. Type lives in title/category instead.
//   - gbp_review_tracker has DUPLICATE rows per review (08-18 seed used
//     maps-URL keys; 08-19 run re-inserted under places/ keys). Matching must
//     return ALL rows (key + author+date ±1d) and flip every waiting twin.
//   - Microsite parse anchors: review-carousel-card.hbs partial comments,
//     first <h3> = author, <p class='text-sm'> = date, blockquote = text,
//     maps/contrib/<id> = stable per-reviewer key ("microsite:<id>").
//   - verify_jwt resets to true on every deploy of some functions — this one
//     deploys with verify_jwt=false; confirm after deploy.
// =============================================================================
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
// Microsite reviews feed (primary readable source)
// -------------------------------------------------------------------------
// The agency's own State Farm microsite renders its /reviews page server-side
// (Mirus mx-static) with the ~25 NEWEST Google reviews, each carrying author,
// date, star rating, full text, and \u2014 critically \u2014 whether the owner reply has
// been posted ("We responded"). That makes it the only feed we can read that
// is sorted by recency AND knows answered-vs-unanswered. Its review data lags
// Google by a few days (corporate sync), which is why the Places rating-count
// watch below stays on as the fast same-hour tripwire.
const MICROSITE_REVIEWS_URL = "https://timberwoodparkinsurance.com/reviews";

function decodeHtmlEntities(s: string): string {
  return s
    .replace(/&quot;/g, '"')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&#x3D;/g, "=")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&");
}

const MONTHS: Record<string, string> = { January: "01", February: "02", March: "03", April: "04", May: "05", June: "06", July: "07", August: "08", September: "09", October: "10", November: "11", December: "12" };

function parseMicrositeDate(s: string): string | null {
  const m = s.trim().match(/^([A-Z][a-z]+) (\d{1,2}), (\d{4})$/);
  if (!m || !MONTHS[m[1]]) return null;
  return `${m[3]}-${MONTHS[m[1]]}-${m[2].padStart(2, "0")}`;
}

interface MicrositeReview { author: string; dateISO: string | null; rating: number | null; text: string; contribId: string | null; hasOwnerResponse: boolean; }

function parseMicrositeReviews(html: string): MicrositeReview[] {
  const cards = html.split("<!-- start partial: m2/reviews/review-carousel-card.hbs -->").slice(1);
  const out: MicrositeReview[] = [];
  for (const rawCard of cards) {
    const card = rawCard.split("<!-- end partial")[0];
    const authorRaw = card.match(/<h3[^>]*>\s*([\s\S]*?)\s*<\/h3>/)?.[1]?.trim();
    if (!authorRaw) continue;
    const dateRaw = card.match(/<p class='text-sm'>\s*([\s\S]*?)\s*<\/p>/)?.[1]?.trim() ?? "";
    const ratingRaw = card.match(/<span class='font-bold'>\s*(\d)\s*<\/span>/)?.[1] ?? "";
    const rating = parseInt(ratingRaw, 10);
    const contribId = card.match(/maps\/contrib\/(\d+)/)?.[1] ?? null;
    const bq = card.match(/<blockquote[^>]*>([\s\S]*?)<\/blockquote>/)?.[1] ?? "";
    let text = decodeHtmlEntities(bq.replace(/<br\s*\/?\s*>/gi, "\n")).trim();
    if (text.startsWith('"') && text.endsWith('"')) text = text.slice(1, -1).trim();
    out.push({
      author: decodeHtmlEntities(authorRaw),
      dateISO: parseMicrositeDate(dateRaw),
      rating: Number.isNaN(rating) ? null : rating,
      text,
      contribId,
      hasOwnerResponse: card.includes("We responded"),
    });
  }
  return out;
}

// Look up tracker rows across sources. Places rows carry
// google_review_name = places/.../reviews/<id>; the 2026-08-18 seed rows carry
// full maps URLs; microsite rows carry microsite:<google contrib id>. The same
// review can exist under more than one key (the 08-19 run duplicated seeded
// rows), so matching returns ALL rows for the review: exact key match plus
// author + publish date (\u00b11 day for timezone drift). No author-only fallback
// \u2014 too loose over years of reviews.
async function findTrackerRows(opts: { googleReviewName?: string | null; author: string; dateISO: string | null }): Promise<any[]> {
  const rows: any[] = [];
  const seen = new Set<string>();
  const push = (arr: any[] | null | undefined) => { for (const r of arr ?? []) { if (r?.id && !seen.has(r.id)) { seen.add(r.id); rows.push(r); } } };
  if (opts.googleReviewName) {
    const { data } = await sb.from("gbp_review_tracker").select("id, status, drafted_response, task_id, google_review_name").eq("place_id", PLACE_ID).eq("google_review_name", opts.googleReviewName).limit(5);
    push(data);
  }
  if (opts.dateISO) {
    const base = new Date(opts.dateISO + "T00:00:00Z").getTime();
    if (!Number.isNaN(base)) {
      const from = new Date(base - 86400000).toISOString();
      const to = new Date(base + 2 * 86400000).toISOString();
      const { data } = await sb.from("gbp_review_tracker")
        .select("id, status, drafted_response, task_id, google_review_name")
        .eq("place_id", PLACE_ID)
        .ilike("author_display_name", opts.author)
        .gte("publish_time", from)
        .lt("publish_time", to)
        .order("created_at", { ascending: true })
        .limit(5);
      push(data);
    }
  }
  return rows;
}

// When one review maps to several rows, act on the most meaningful one:
// a row that already holds a draft wins (prevents re-drafting), then any
// non-historical row, then whatever is left.
function pickPrimaryRow(rows: any[]): any | null {
  if (!rows.length) return null;
  return rows.find((r) => r.drafted_response) ?? rows.find((r) => r.status !== "historical") ?? rows[0];
}

async function createReviewTask(agencyId: string, authorName: string, rating: number | null, reviewText: string, draftedResponse: string): Promise<string | null> {
  // task_type must be one of epic/story/task (tasks_task_type_check) \u2014 an
  // earlier version inserted "review_response" here and every task insert
  // failed silently against that CHECK constraint. The review context lives in
  // the title and task_category instead.
  const { data: task, error } = await sb.from("tasks").insert({
    agency_id: agencyId,
    title: `New Google review from ${authorName} (${rating ?? "?"}\u2605) \u2014 response drafted`,
    description: `Review: "${reviewText}"\n\nDrafted response (ready to paste at business.google.com > Reviews):\n\n${draftedResponse}`,
    task_category: "marketing",
    task_type: "task",
    priority: (rating ?? 5) <= 3 ? "high" : "medium",
    status: "open",
    created_by: "gbp_review_checker",
  }).select("id").single();
  if (error) { console.error(`task insert failed: ${error.message}`); return null; }
  return task?.id ?? null;
}

interface MicrositePassResult { ok: boolean; parsed: number; unanswered: number; marked_responded: number; drafted: number; failed: number; note?: string; }

async function micrositePass(ctx: { agencyId: string; groqApiKey: string; recentOpenings: string[]; botToken: string | null; chatId: string | null; alviTelegramUserId: number | null; }): Promise<MicrositePassResult> {
  const { res, timedOut } = await fetchWithTimeout(
    MICROSITE_REVIEWS_URL,
    { headers: { "User-Agent": "Mozilla/5.0 (compatible; NewtworksReviewBot/1.0)" } },
    15000, "microsite", "reviews page fetch",
    { agencyId: ctx.agencyId, moduleReference: "gbp_reviews", context: "microsite /reviews fetch" },
  );
  if (!res || !res.ok) {
    return { ok: false, parsed: 0, unanswered: 0, marked_responded: 0, drafted: 0, failed: 0, note: `microsite fetch failed (${res ? `HTTP ${res.status}` : timedOut ? "timeout" : "network error"})` };
  }
  const html = await res.text();
  const reviews = parseMicrositeReviews(html);
  let markedResponded = 0, drafted = 0, failed = 0, unanswered = 0;
  let groqCapped = false;

  for (const rv of reviews) {
    const key = rv.contribId ? `microsite:${rv.contribId}` : null;
    const matches = await findTrackerRows({ googleReviewName: key, author: rv.author, dateISO: rv.dateISO });

    if (rv.hasOwnerResponse) {
      // Reply already live on Google \u2014 close the loop on EVERY row for this
      // review that is still waiting (duplicates included).
      let flipped = false;
      for (const m of matches) {
        if (m.status !== "responded" && m.status !== "historical") {
          await sb.from("gbp_review_tracker").update({ status: "responded" }).eq("id", m.id);
          if (m.task_id) await sb.from("tasks").update({ status: "completed" }).eq("id", m.task_id);
          flipped = true;
        }
      }
      if (flipped) markedResponded++;
      continue;
    }

    unanswered++;
    const existing = pickPrimaryRow(matches);
    if (existing && existing.drafted_response) continue; // draft already out, awaiting posting
    if (groqCapped) { failed++; continue; }

    const userContent = JSON.stringify({ reviewer_first_name: rv.author.split(" ")[0], rating: rv.rating, review_text: rv.text, recent_openings_to_avoid: ctx.recentOpenings });
    const g = await callGroq(ctx.agencyId, ctx.groqApiKey, userContent);

    if (g.ok && g.text) {
      const taskId = await createReviewTask(ctx.agencyId, rv.author, rv.rating, rv.text, g.text);
      if (existing) {
        await sb.from("gbp_review_tracker").update({ drafted_response: g.text, status: "drafted", task_id: taskId, rating: rv.rating, review_text: rv.text }).eq("id", existing.id);
      } else {
        await sb.from("gbp_review_tracker").insert({ agency_id: ctx.agencyId, place_id: PLACE_ID, google_review_name: key ?? `microsite:${rv.author}:${rv.dateISO ?? "unknown"}`, author_display_name: rv.author, rating: rv.rating, review_text: rv.text, publish_time: rv.dateISO ? rv.dateISO + "T12:00:00Z" : null, drafted_response: g.text, task_id: taskId, status: "drafted" });
      }
      if (ctx.botToken && ctx.chatId) {
        await sendTelegramReviewAlert({ botToken: ctx.botToken, chatId: ctx.chatId, alviTelegramUserId: ctx.alviTelegramUserId, authorName: rv.author, rating: rv.rating, reviewText: rv.text, draftedResponse: g.text });
      }
      ctx.recentOpenings.unshift(g.text.split(" ").slice(0, 5).join(" "));
      drafted++;
    } else {
      failed++;
      if ((g.error ?? "").includes("429")) groqCapped = true;
      let relatedId: string | null = existing?.id ?? null;
      if (existing) {
        if (existing.status !== "draft_failed") await sb.from("gbp_review_tracker").update({ status: "draft_failed", rating: rv.rating, review_text: rv.text }).eq("id", existing.id);
      } else {
        const { data: inserted } = await sb.from("gbp_review_tracker").insert({ agency_id: ctx.agencyId, place_id: PLACE_ID, google_review_name: key ?? `microsite:${rv.author}:${rv.dateISO ?? "unknown"}`, author_display_name: rv.author, rating: rv.rating, review_text: rv.text, publish_time: rv.dateISO ? rv.dateISO + "T12:00:00Z" : null, drafted_response: null, task_id: null, status: "draft_failed" }).select("id").maybeSingle();
        relatedId = inserted?.id ?? null;
      }
      await insertAlert({
        agencyId: ctx.agencyId,
        alertType: "gbp_review_draft_failed",
        severity: "warning",
        title: `Google review reply could not be drafted (${rv.author})`,
        message: `An unanswered Google review (from the microsite reviews feed) failed reply drafting. Reason: ${g.error ?? "unknown"}. Stored as draft_failed; the hourly run retries automatically.`,
        moduleReference: "gbp_reviews",
        relatedId,
      });
    }
  }

  return { ok: true, parsed: reviews.length, unanswered, marked_responded: markedResponded, drafted, failed };
}

// -------------------------------------------------------------------------
// Rating-count watch
// -------------------------------------------------------------------------
// Places userRatingCount is the listing's true total and moves the moment any
// review or star rating lands \u2014 days before the microsite sync catches up.
// Stored total lives in settings (gbp_last_known_rating_count); a rise without
// a matching readable review alerts + pings the team to reply by hand.
// Removed reviews (count drops) just resync silently.
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
    title: `Google shows ${missed} new review(s) not yet readable`,
    message: `The listing's total rating count rose from ${stored} to ${totalRatingCount}, but ${missed} of the new reviews are not yet readable (Places shows only 5 relevance-ranked reviews; the microsite feed syncs on a delay). Someone should reply manually at business.google.com > Reviews; the microsite feed will pick it up automatically within a few days if not. Durable fix: Google Business Profile API access.`,
    moduleReference: "gbp_reviews",
  });

  if (opts.botToken && opts.chatId) {
    const tagHtml = opts.alviTelegramUserId ? `<a href="tg://user?id=${opts.alviTelegramUserId}">Alvi</a>` : "Alvi";
    const plural = missed === 1 ? "review" : "reviews";
    await sendTelegram(opts.botToken, opts.chatId, `\u2B50 <b>${missed} new Google ${plural}</b> just landed. The text isn't readable to the bot yet (site feed syncs on a delay), so if you want to reply today: business.google.com &gt; Reviews, sort by newest.\n\n${tagHtml} \u2014 otherwise the bot will catch it with a drafted reply as soon as the feed syncs (usually within a few days).`);
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

FORMULA \u2014 every response, 2-4 sentences, hits these once each, naturally:
1. Reviewer's first name
2. One specific detail from THEIR review (product, teammate, situation)
3. Business/team mentioned once ("our team", not always the business name)
4. Vary sentence structure and opening phrase every time \u2014 you will be shown the last several openings used; NEVER repeat one of them or anything structurally similar.

HARD COMPLIANCE RULES (State Farm agent's agreement \u2014 violating any of these is a real compliance issue, not a style note):
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
// way a fresh review would be: draft stored, task created, Telegram sent \u2014
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
      const taskId = await createReviewTask(opts.agencyId, authorName, row.rating, row.review_text ?? "", g.text);
      await sb.from("gbp_review_tracker").update({ drafted_response: g.text, status: "drafted", task_id: taskId }).eq("id", row.id);
      if (opts.botToken && opts.chatId) {
        await sendTelegramReviewAlert({ botToken: opts.botToken, chatId: opts.chatId, alviTelegramUserId: opts.alviTelegramUserId, authorName, rating: row.rating, reviewText: row.review_text ?? "", draftedResponse: g.text });
      }
      opts.recentOpenings.unshift(g.text.split(" ").slice(0, 5).join(" "));
      out.push({ id: row.id, author: authorName, ok: true, task_id: taskId });
    } else {
      out.push({ id: row.id, author: authorName, ok: false, error: g.error });
      if ((g.error ?? "").includes("429")) break; // capped \u2014 stop hammering
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

  // 1) Microsite pass \u2014 the recency-ordered readable feed. Runs FIRST so that
  // reviews already answered on Google get flipped to responded before the
  // retry logic below can waste drafting tokens on them.
  const micrositeResult = await micrositePass({ agencyId, groqApiKey, recentOpenings, botToken: telegramBotToken, chatId: telegramChatId, alviTelegramUserId });

  // 2) Hourly self-heal: quietly retry stuck rows so a capped or flaky
  // drafting day converges on its own instead of waiting for maintenance.
  const autoRedrafted = await redraftFailedRows({ agencyId, groqApiKey, recentOpenings, limit: 3, botToken: telegramBotToken, chatId: telegramChatId, alviTelegramUserId });

  // 3) Places pass \u2014 5 relevance-ranked reviews (rarely surfaces anything new)
  // plus userRatingCount for the same-hour count watch.
  const composioResult = await callComposio({ apiKey, userId, connectedAccountId: mapsAccountId, toolSlug: "GOOGLE_MAPS_GET_PLACE_DETAILS", toolArguments: { name: `places/${PLACE_ID}`, fieldMask: "id,displayName,rating,userRatingCount,reviews" }, toolkitVersion: "latest" });
  if (!composioResult.ok) {
    return jsonResponse({ ok: true, microsite: micrositeResult, auto_redrafted: autoRedrafted, places_error: `Google Maps call failed: ${composioResult.error}`, count_watch: { baseline_seeded: false, missed: 0 } });
  }

  const reviews: any[] = composioResult.data?.reviews ?? [];
  const totalRatingCount: number | null = composioResult.data?.userRatingCount ?? null;

  const results: any[] = [];
  let alreadyKnown = 0;

  for (const rev of reviews) {
    const googleReviewName: string = rev.name;
    const authorName: string = rev.authorAttribution?.displayName ?? "there";
    const rating: number = rev.rating ?? null;
    const text: string = rev.text?.text ?? rev.originalText?.text ?? "";
    const publishTime: string | null = rev.publishTime ?? null;

    const existing = pickPrimaryRow(await findTrackerRows({ googleReviewName, author: authorName, dateISO: publishTime ? publishTime.slice(0, 10) : null }));
    if (existing) { alreadyKnown++; continue; }

    const userContent = JSON.stringify({ reviewer_first_name: authorName.split(" ")[0], rating, review_text: text, recent_openings_to_avoid: recentOpenings });
    const groqResult = await callGroq(agencyId, groqApiKey, userContent);
    const draftedResponse = groqResult.ok ? groqResult.text : null;

    let taskId: string | null = null;
    if (draftedResponse) {
      taskId = await createReviewTask(agencyId, authorName, rating, text, draftedResponse);
      if (telegramBotToken && telegramChatId) {
        await sendTelegramReviewAlert({ botToken: telegramBotToken, chatId: telegramChatId, alviTelegramUserId, authorName, rating, reviewText: text, draftedResponse });
      }
    }

    const { data: inserted } = await sb.from("gbp_review_tracker").insert({ agency_id: agencyId, place_id: PLACE_ID, google_review_name: googleReviewName, author_display_name: authorName, rating, review_text: text, publish_time: publishTime, drafted_response: draftedResponse, task_id: taskId, status: draftedResponse ? "drafted" : "draft_failed" }).select("id").maybeSingle();

    // A review that lands but never gets a draft produces no task and no
    // Telegram message. Without this alert that failure is completely silent \u2014
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

  const watch = await ratingCountWatch({ agencyId, totalRatingCount, newInserted: results.length + micrositeResult.drafted + micrositeResult.failed, botToken: telegramBotToken, chatId: telegramChatId, alviTelegramUserId });

  return jsonResponse({
    ok: true,
    microsite: micrositeResult,
    auto_redrafted: autoRedrafted,
    places: { new_reviews: results.length, fetched: reviews.length, already_known: alreadyKnown, results },
    total_rating_count: totalRatingCount,
    count_watch: watch,
    source_note: "microsite /reviews = recency feed with answered-status (syncs on a delay); Places = 5 relevance-ranked + live rating count for the same-hour watch",
  });
});
