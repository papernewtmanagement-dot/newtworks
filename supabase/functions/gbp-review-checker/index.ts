// =========================================================================
// gbp-review-checker
// =========================================================================
// v2 (2026-08-18): Runs HOURLY (not weekly — the 5-review-per-call cap on
// Google Maps' API means a weekly cadence could silently drop reviews on
// weeks with 6+ new ones; hourly makes that a non-issue in practice).
// Pulls the 5 most recent Google Business Profile reviews via Composio's
// Google Maps GET_PLACE_DETAILS tool, diffs against gbp_review_tracker
// (keyed on place_id + google review resource name), and for anything new:
// drafts a response with Groq (compliance-guardrailed, varied against the
// last 10 drafted openings so nothing echoes), posts it to the Paper Newt
// Management Telegram group tagging Alvi (team record: Marie Story,
// alvipelo@gmail.com — flagged once in commit history, not silently
// assumed), AND inserts a `tasks` row as the durable paper trail. Google's
// Business Profile reply API is invite-only, so posting is still manual —
// this gets the draft in front of a human (fast, via Telegram) as soon as
// possible after the review lands.
//
// Invoked by pg_cron via dispatch_gbp_review_checker (automation-runner's
// INTERNAL/dispatch_ branch does a direct fetch to /functions/v1/gbp-
// review-checker). See op-rule "Newtworks dispatch_* recipe convention".
// =========================================================================

// deno-lint-ignore-file no-explicit-any
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { callComposio } from "../_shared/composio.ts";
import { sb, jsonResponse, getSetting, AGENCY_ID_DEFAULT } from "../_shared/supabase.ts";
import { requireSharedSecret } from "../_shared/auth.ts";

async function sendTelegramReviewAlert(opts: {
  botToken: string;
  chatId: string;
  alviTelegramUserId: number | null;
  authorName: string;
  rating: number | null;
  reviewText: string;
  draftedResponse: string;
}): Promise<void> {
  const stars = opts.rating != null ? "★".repeat(Math.max(0, Math.min(5, Math.round(opts.rating)))) : "";
  const tagHtml = opts.alviTelegramUserId
    ? `<a href="tg://user?id=${opts.alviTelegramUserId}">Alvi</a>`
    : "Alvi";
  const escape = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const text =
    `🆕 <b>New Google review</b> — ${escape(opts.authorName)} (${stars})\n\n` +
    `"${escape(opts.reviewText).slice(0, 400)}"\n\n` +
    `<b>Drafted reply</b> (paste at business.google.com &gt; Reviews):\n${escape(opts.draftedResponse)}\n\n` +
    `${tagHtml} — can you post this one?`;
  try {
    await fetch(`https://api.telegram.org/bot${opts.botToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: opts.chatId,
        text,
        parse_mode: "HTML",
        disable_web_page_preview: true,
      }),
    });
  } catch (e) {
    console.error(`Telegram send failed: ${(e as Error).message}`);
  }
}

const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions";
const LLM_MODEL_FALLBACK = "openai/gpt-oss-120b";
const PLACE_ID = "ChIJn5BEWaWHXIYR-u4V6qmytzM"; // Peter Story - State Farm Insurance Agent

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
  const body = {
    model,
    messages: [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: userContent },
    ],
    temperature: 0.7,
    max_tokens: 300,
    response_format: { type: "json_object" },
  };
  const res = await fetch(GROQ_API_URL, {
    method: "POST",
    headers: { "Authorization": `Bearer ${groqApiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const raw = await res.text();
  if (!res.ok) return { ok: false, text: null, error: `Groq HTTP ${res.status}: ${raw.slice(0, 300)}` };
  try {
    const parsed = JSON.parse(raw);
    const content = parsed?.choices?.[0]?.message?.content;
    if (!content) return { ok: false, text: null, error: "Groq returned empty content" };
    const extracted = JSON.parse(content);
    return { ok: true, text: extracted.response_text ?? null, error: null };
  } catch (e) {
    return { ok: false, text: null, error: `Groq parse failure: ${(e as Error).message}` };
  }
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
  const alviTelegramUserIdRaw = await getSetting(agencyId, "marie_telegram_user_id"); // team record for alvipelo@gmail.com
  const alviTelegramUserId = alviTelegramUserIdRaw ? parseInt(alviTelegramUserIdRaw, 10) : null;
  if (!apiKey || !userId || !mapsAccountId) {
    return jsonResponse({ ok: false, error: "missing Composio Google Maps credentials in settings" }, 500);
  }
  if (!groqApiKey) {
    return jsonResponse({ ok: false, error: "missing groq_api_key in settings" }, 500);
  }

  const composioResult = await callComposio({
    apiKey,
    userId,
    connectedAccountId: mapsAccountId,
    toolSlug: "GOOGLE_MAPS_GET_PLACE_DETAILS",
    toolArguments: { name: `places/${PLACE_ID}`, fieldMask: "id,displayName,rating,userRatingCount,reviews" },
  });

  if (!composioResult.ok) {
    return jsonResponse({ ok: false, error: `Google Maps call failed: ${composioResult.error}` }, 500);
  }

  const reviews: any[] = composioResult.data?.reviews ?? [];
  if (reviews.length === 0) {
    return jsonResponse({ ok: true, new_reviews: 0, note: "no reviews returned" });
  }

  // Recent-opening ledger, so new drafts don't echo the last several.
  const { data: recentDrafts } = await sb
    .from("gbp_review_tracker")
    .select("drafted_response")
    .eq("agency_id", agencyId)
    .not("drafted_response", "is", null)
    .order("created_at", { ascending: false })
    .limit(10);
  const recentOpenings = (recentDrafts ?? [])
    .map((r: any) => (r.drafted_response as string).split(" ").slice(0, 5).join(" "))
    .filter(Boolean);

  const results: any[] = [];

  for (const rev of reviews) {
    const googleReviewName: string = rev.name; // places/{id}/reviews/{reviewId} — stable resource name
    const authorName: string = rev.authorAttribution?.displayName ?? "there";
    const rating: number = rev.rating ?? null;
    const text: string = rev.text?.text ?? rev.originalText?.text ?? "";
    const publishTime: string | null = rev.publishTime ?? null;

    const { data: existing } = await sb
      .from("gbp_review_tracker")
      .select("id")
      .eq("place_id", PLACE_ID)
      .eq("google_review_name", googleReviewName)
      .maybeSingle();

    if (existing) continue; // already tracked, nothing to do

    const userContent = JSON.stringify({
      reviewer_first_name: authorName.split(" ")[0],
      rating,
      review_text: text,
      recent_openings_to_avoid: recentOpenings,
    });

    const groqResult = await callGroq(agencyId, groqApiKey, userContent);
    const draftedResponse = groqResult.ok ? groqResult.text : null;

    // Create a task for Peter to review + paste (Google's reply API is invite-only, no auto-post).
    let taskId: string | null = null;
    if (draftedResponse) {
      const { data: task, error: taskErr } = await sb
        .from("tasks")
        .insert({
          agency_id: agencyId,
          title: `New Google review from ${authorName} (${rating}★) — response drafted`,
          description: `Review: "${text}"\n\nDrafted response (ready to paste at business.google.com > Reviews):\n\n${draftedResponse}`,
          task_category: "marketing",
          task_type: "review_response",
          priority: rating <= 3 ? "high" : "medium",
          status: "open",
          created_by: "gbp_review_checker",
        })
        .select("id")
        .single();
      if (!taskErr) taskId = task?.id ?? null;

      if (telegramBotToken && telegramChatId) {
        await sendTelegramReviewAlert({
          botToken: telegramBotToken,
          chatId: telegramChatId,
          alviTelegramUserId,
          authorName,
          rating,
          reviewText: text,
          draftedResponse,
        });
      }
    }

    await sb.from("gbp_review_tracker").insert({
      agency_id: agencyId,
      place_id: PLACE_ID,
      google_review_name: googleReviewName,
      author_display_name: authorName,
      rating,
      review_text: text,
      publish_time: publishTime,
      drafted_response: draftedResponse,
      task_id: taskId,
      status: draftedResponse ? "drafted" : "draft_failed",
    });

    if (draftedResponse) recentOpenings.unshift(draftedResponse.split(" ").slice(0, 5).join(" "));
    results.push({ author: authorName, rating, drafted: !!draftedResponse, task_id: taskId });
  }

  return jsonResponse({ ok: true, new_reviews: results.length, results });
});
