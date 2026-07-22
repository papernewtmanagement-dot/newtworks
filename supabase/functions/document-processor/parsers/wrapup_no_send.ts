// Wrap-up no-send check parser (2026-07-22).
//
// Purpose: fires once at Fri 7 PM CT (via cron `0 0 * * 6` UTC). Checks
// which teammates have submitted NO wrap-up yet for the current week and:
//   1. Emails each missing teammate (to: teammate SF email, cc: Peter)
//   2. Sends ONE group Telegram message via pjsagencybot to PJS Agency
//      chat naming every missing teammate
//
// Design choices (Peter directive 2026-07-22):
// - Recipient of email = teammate + Peter cc'd (not whole team)
// - Telegram = single GROUP message via pjsagencybot (not personal DM)
// - Single fire per week (no repeat throttle needed structurally, but
//   wrapup_nag_log hash guard added for defense against duplicate cron ticks)
// - dry_run: true in body → compose but do not send; return would-send list
//
// Related: parsers/wrapup_ingest.ts (per-partial-submission nag path)

import { sb } from "../lib/supabase.ts";
import { callComposio } from "../lib/composio.ts";

export interface WrapupNoSendCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
}

export interface WrapupNoSendBody {
  mode: "no_send_check";
  dry_run?: boolean;         // If true: no sends, just return plan
  target_week?: string;      // Optional YYYY-MM-DD override; else computed
}

interface MissingTeammate {
  id: string;
  first_name: string;
  email_sf: string;
}

// Compute the current week-ending Saturday in CT. Fri 7 PM CT (= Sat 00:00 UTC)
// tick lands on Fri CT wall-clock → target Sat is tomorrow.
function currentSaturdayCT(now: Date): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago",
    year: "numeric", month: "2-digit", day: "2-digit", weekday: "short",
  }).formatToParts(now);
  const y = parts.find(p => p.type === "year")!.value;
  const m = parts.find(p => p.type === "month")!.value;
  const d = parts.find(p => p.type === "day")!.value;
  const wd = parts.find(p => p.type === "weekday")!.value;
  const dayIdx: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  const idx = dayIdx[wd] ?? 0;
  // Days forward to next Sat (Sat itself → 0)
  const daysOffset = idx === 6 ? 0 : 6 - idx;
  const base = new Date(`${y}-${m}-${d}T12:00:00Z`);
  base.setUTCDate(base.getUTCDate() + daysOffset);
  return base.toISOString().slice(0, 10);
}

const PETER_SF_EMAIL = "peter.story.yrru@statefarm.com";
const NO_SEND_MARKER = "__NO_SEND__";

export async function processWrapupNoSendMode(
  ctx: WrapupNoSendCtx,
  body: WrapupNoSendBody,
): Promise<Record<string, unknown>> {
  const startedAt = new Date().toISOString();
  const dryRun = body.dry_run === true;
  const targetWeek = body.target_week || currentSaturdayCT(new Date());

  console.log(`[no_send_check] target_week=${targetWeek} dry_run=${dryRun}`);

  // 1. Look up weekly_cpr_reports row for the target week
  const { data: reportRow, error: reportErr } = await sb
    .from("weekly_cpr_reports")
    .select("id")
    .eq("agency_id", ctx.agencyId)
    .eq("week_ending_date", targetWeek)
    .maybeSingle();
  if (reportErr) {
    console.error(`[no_send_check] weekly_cpr_reports lookup failed: ${reportErr.message}`);
    return { ok: false, error: `weekly_cpr_reports lookup: ${reportErr.message}`, target_week: targetWeek, started_at: startedAt };
  }
  if (!reportRow?.id) {
    console.log(`[no_send_check] no weekly_cpr_reports row for ${targetWeek} — cannot check`);
    return { ok: true, target_week: targetWeek, missing: [], skipped: "no_report_row", dry_run: dryRun, started_at: startedAt };
  }

  // 2. Pull rostered teammates who have NO wrapup_text yet
  //    Filter matches wrapup_ingest.ts (agency, active, not archived,
  //    not admin_backoffice, not Owner).
  const { data: teamRows, error: teamErr } = await sb
    .from("team")
    .select("id, first_name, email_sf, role_level, weekly_cpr_team_detail!inner(wrapup_text,weekly_cpr_report_id)")
    .eq("agency_id", ctx.agencyId)
    .eq("category", "agency")
    .eq("is_active", true)
    .is("archived_at", null)
    .eq("is_admin_backoffice", false)
    .eq("weekly_cpr_team_detail.weekly_cpr_report_id", reportRow.id);
  if (teamErr) {
    console.error(`[no_send_check] roster query failed: ${teamErr.message}`);
    return { ok: false, error: `roster query: ${teamErr.message}`, target_week: targetWeek, started_at: startedAt };
  }

  const missing: MissingTeammate[] = [];
  for (const row of teamRows || []) {
    // Skip Owner (Peter)
    if ((row.role_level || "") === "Owner") continue;
    const details = (row as any).weekly_cpr_team_detail as Array<{ wrapup_text: string | null }>;
    const anyText = (details || []).some(d => (d.wrapup_text || "").trim().length > 0);
    if (anyText) continue;
    const email = (row.email_sf || "").trim();
    if (!email) continue;  // Can't email them, skip
    missing.push({ id: row.id, first_name: row.first_name, email_sf: email });
  }

  console.log(`[no_send_check] ${missing.length} missing teammate(s): ${missing.map(m => m.first_name).join(", ")}`);

  if (missing.length === 0) {
    return { ok: true, target_week: targetWeek, missing: [], dry_run: dryRun, started_at: startedAt, finished_at: new Date().toISOString() };
  }

  // 3. Compose email per missing teammate; hash-throttle via wrapup_nag_log
  const hashRes = await sb.rpc("wrapup_missing_items_hash", { p_missing: [NO_SEND_MARKER] });
  const hash: string = (hashRes.data as string) || "";
  if (!hash) {
    return { ok: false, error: "hash computation failed", target_week: targetWeek, started_at: startedAt };
  }

  const emailResults: Array<Record<string, unknown>> = [];
  for (const tm of missing) {
    // Throttle check
    const { data: prior } = await sb
      .from("wrapup_nag_log")
      .select("id")
      .eq("agency_id", ctx.agencyId)
      .eq("team_member_id", tm.id)
      .eq("week_ending_date", targetWeek)
      .eq("missing_items_hash", hash)
      .maybeSingle();
    if (prior?.id) {
      console.log(`[no_send_check] ${tm.first_name}: already logged for week ${targetWeek}, skipping`);
      emailResults.push({ team_member_id: tm.id, first_name: tm.first_name, skipped: "already_logged" });
      continue;
    }

    const subject = `Wrap-up — haven't seen yours yet this week`;
    const body =
`Hey ${tm.first_name},

Haven't seen your wrap-up email land yet. Send it before Saturday so it lands in this week's CPR.

The six items:

  1. Personal life and annuity status updates — your book, pending apps, upcoming reviews
  2. Lapse/cancel trends + individual highlights — trends you're seeing and specific wins
  3. Personal obstacles you're running into + solutions you propose
  4. Your plan for a 1% increase in sales points next week
  5. A recommendation to make the office more efficient / remove pain points for the whole team
  6. Brags on teammates — something you saw them do that matched our mission statement or job description

Reply here or fire a fresh email — whichever's easier.

— Peter
`;

    if (dryRun) {
      emailResults.push({ team_member_id: tm.id, first_name: tm.first_name, would_send_to: tm.email_sf, cc: PETER_SF_EMAIL, subject, dry_run: true });
      continue;
    }

    // Live send
    const sendRes = await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_SEND_EMAIL",
      toolArguments: {
        recipient_email: tm.email_sf,
        cc: [PETER_SF_EMAIL],
        subject,
        body,
        is_html: false,
        user_id: "me",
      },
    });
    if (!sendRes.ok) {
      console.warn(`[no_send_check] send failed for ${tm.first_name}: ${sendRes.error}`);
      emailResults.push({ team_member_id: tm.id, first_name: tm.first_name, error: sendRes.error });
      continue;
    }

    const sentGmailId: string | null =
      sendRes.data?.id ?? sendRes.data?.messageId ?? sendRes.data?.response_data?.id ?? null;

    await sb.from("wrapup_nag_log").insert({
      agency_id: ctx.agencyId,
      team_member_id: tm.id,
      week_ending_date: targetWeek,
      missing_items_hash: hash,
      missing_items: [NO_SEND_MARKER],
      gmail_message_id: sentGmailId,
      trigger_email_id: null,
    });

    emailResults.push({ team_member_id: tm.id, first_name: tm.first_name, sent: true, gmail_message_id: sentGmailId });
  }

  // 4. Send ONE group Telegram message via pjsagencybot to PJS Agency chat
  const missingNames = missing.map(m => m.first_name).join(", ");
  const telegramText =
`📝 Wrap-up not in yet from: ${missingNames}

Send it before Saturday so it lands in this week's CPR — reply to any wrap-up thread or fire a fresh email.`;

  let telegramResult: Record<string, unknown>;
  if (dryRun) {
    telegramResult = { would_send: true, chat_id: -5377408548, text_preview: telegramText, dry_run: true };
  } else {
    // Pull chat_id from settings for defense in depth (default matches op-rule)
    const { data: chatIdSetting } = await sb
      .from("settings")
      .select("setting_value")
      .eq("setting_key", "telegram_team_group_chat_id")
      .maybeSingle();
    const chatId = chatIdSetting?.setting_value ? parseInt(chatIdSetting.setting_value, 10) : -5377408548;

    const tgRes = await sb.rpc("telegram_send_message_v2", {
      p_chat_id: chatId,
      p_text: telegramText,
      p_bot: "pjsagency",
    });
    if (tgRes.error) {
      console.warn(`[no_send_check] telegram group send failed: ${tgRes.error.message}`);
      telegramResult = { error: tgRes.error.message };
    } else {
      telegramResult = { sent: true, chat_id: chatId, response: tgRes.data };
    }
  }

  return {
    ok: true,
    mode: "no_send_check",
    target_week: targetWeek,
    dry_run: dryRun,
    missing_count: missing.length,
    email_results: emailResults,
    telegram_result: telegramResult,
    started_at: startedAt,
    finished_at: new Date().toISOString(),
  };
}
