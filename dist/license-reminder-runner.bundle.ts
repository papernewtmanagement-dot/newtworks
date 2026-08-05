// =========================================================================
// license-reminder-runner bundle (auto-generated)
// Source of truth: supabase/functions/license-reminder-runner/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py license-reminder-runner`.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

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

// ==================== _shared/auth.ts ====================
// =========================================================================
// _shared/auth.ts
// =========================================================================
// Canonical shared-secret gate for cron/internally-dispatched edge functions.
// The dispatch side (_dispatch_edge_fn, run_automation_recipe, automation-
// runner INTERNAL handlers) POSTs { agency_id, shared_secret } in the body;
// the secret must match settings.automation_runner_cron_secret.
//
// Usage in a handler:
//   const denied = await requireSharedSecret(agencyId, body.shared_secret);
//   if (denied) return denied;
// =========================================================================


async function requireSharedSecret(
  agencyId: string,
  provided: string | undefined | null,
): Promise<Response | null> {
  if (!provided) {
    return jsonResponse({ ok: false, error: "missing shared_secret" }, 401);
  }
  const expected = await getSettingOrNull(agencyId, "automation_runner_cron_secret");
  if (!expected || provided !== expected) {
    return jsonResponse({ ok: false, error: "unauthorized" }, 401);
  }
  return null;
}

// ==================== _shared/composio.ts ====================
// =========================================================================
// _shared/composio.ts
// =========================================================================
// Canonical Composio HTTP wrapper for ALL Newtworks edge functions. This is
// the one true copy of callComposio — every function that used to carry its
// own inline copy now bundles this file via scripts/bundle_edge_fn.py.
// =========================================================================

const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";

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
}): Promise<ComposioCallResult> {
  const res = await fetch(`${COMPOSIO_BASE}/${opts.toolSlug}`, {
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
  });
  const text = await res.text();
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = res.ok && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok
    ? null
    : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: res.status };
}

async function callComposioNoAuth(opts: {
  apiKey: string;
  userId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
}): Promise<ComposioCallResult> {
  const res = await fetch(`${COMPOSIO_BASE}/${opts.toolSlug}`, {
    method: "POST",
    headers: {
      "x-api-key": opts.apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      user_id: opts.userId,
      arguments: opts.toolArguments,
    }),
  });
  const text = await res.text();
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = res.ok && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok
    ? null
    : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: res.status };
}

// ==================== _shared/gmail.ts ====================
// =========================================================================
// _shared/gmail.ts
// =========================================================================
// Canonical "send an email through Composio Gmail" path for ALL Newtworks
// edge functions. Replaces the settings-triplet fetch + GMAIL_SEND_EMAIL
// call that used to be copy-pasted into txn-coding-question-mailer,
// license-reminder-runner, pfa-reconciliation-send, terminate-team-member
// and the document-processor wrap-up parsers.
//
// The sender account is Composio-managed paper.newt.management@gmail.com.
// =========================================================================


interface GmailCreds {
  apiKey: string;
  userId: string;
  accountId: string;
}

// One batch settings query for the three Composio Gmail credentials.
async function getComposioGmailCreds(
  agencyId: string,
): Promise<{ ok: true; creds: GmailCreds } | { ok: false; error: string }> {
  let map: Record<string, string | null>;
  try {
    map = await getSettings(agencyId, [
      "composio_api_key",
      "composio_user_id",
      "composio_gmail_account_id",
    ]);
  } catch (e) {
    return { ok: false, error: `settings read failed: ${(e as Error).message}` };
  }
  const apiKey = map["composio_api_key"];
  const userId = map["composio_user_id"];
  const accountId = map["composio_gmail_account_id"];
  if (!apiKey || !userId || !accountId) {
    return { ok: false, error: "missing Composio Gmail credentials in settings" };
  }
  return { ok: true, creds: { apiKey, userId, accountId } };
}

// Send one email. Exactly one of html / text should be provided.
// attachment (if any) must already be staged with Composio — GMAIL_SEND_EMAIL
// only accepts { name, mimetype, s3key } pointers, never raw bytes.
async function sendGmail(opts: {
  creds: GmailCreds;
  to: string;
  subject: string;
  html?: string;
  text?: string;
  cc?: string[];
  attachment?: { name: string; mimetype: string; s3key: string };
}): Promise<ComposioCallResult> {
  const args: Record<string, any> = {
    recipient_email: opts.to,
    subject: opts.subject,
    body: opts.html ?? opts.text ?? "",
    is_html: opts.html != null,
    user_id: "me",
  };
  if (opts.cc && opts.cc.length > 0) args.cc = opts.cc;
  if (opts.attachment) args.attachment = opts.attachment;

  return await callComposio({
    apiKey: opts.creds.apiKey,
    userId: opts.creds.userId,
    connectedAccountId: opts.creds.accountId,
    toolSlug: "GMAIL_SEND_EMAIL",
    toolArguments: args,
  });
}

// ==================== license-reminder-runner/index.ts ====================
// =========================================================================
// license-reminder-runner
// =========================================================================
// Daily job that:
//   1) Reads active rows from public.team_licenses
//   2) Upserts an alerts row per license (severity scales with days_until_due)
//   3) On cadence days (90/60/30/14/7/1/0 or negative for past-due) sends a
//      reminder email to the team member's email_personal AND email_sf, cc
//      Peter for high/critical. Skips CE reminders where ce_required=false.
//   4) Logs each send to license_notification_log so we don't double-send.
//
// Invoked by pg_cron via dispatch_license_reminders() (see companion SQL).
// =========================================================================

// deno-lint-ignore-file no-explicit-any

const OWNER_EMAIL = "storypeterj@gmail.com";
const TZ = "America/Chicago";

const CADENCE_DAYS_BEFORE = [90, 60, 30, 14, 7, 1, 0];

const LICENSE_LABELS: Record<string, string> = {
  insurance_ce: "Insurance CE",
  annuities_ce: "Annuities CE",
  medicare_ce: "Medicare CE",
  insurance_license: "State Insurance License Renewal",
  long_term_care: "Long-Term Care Certification",
  series_6_annual_compliance: "Series 6 Annual Compliance Training",
  series_6_regulatory_element: "Series 6 Regulatory Element (FinPro)",
  chfc_ce: "ChFC/CLU Continuing Education",
  chfc_recert_payment: "ChFC/CLU Recertification Payment",
  mortgage_ce: "Mortgage NMLS CE",
  mortgage_license: "Mortgage NMLS License Renewal",
  humana_recert: "Humana Annual Recertification",
  us_bank_personal: "US Bank Personal Compliance",
  jackson_training: "Jackson National Product Training",
  bcbs_cert: "BCBS Certification",
  trupanion_cert: "Trupanion Certification",
  gainsco_cert: "GAINSCO Training",
};

function labelFor(t: string): string {
  return LICENSE_LABELS[t] ?? t;
}

function severityForDays(daysOut: number): string {
  if (daysOut < 0) return "critical";
  if (daysOut <= 1) return "critical";
  if (daysOut <= 14) return "high";
  if (daysOut <= 30) return "warning";
  return "info";
}

function todayInCT(): string {
  const now = new Date();
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const y = parts.find((p) => p.type === "year")!.value;
  const m = parts.find((p) => p.type === "month")!.value;
  const d = parts.find((p) => p.type === "day")!.value;
  return `${y}-${m}-${d}`;
}

function daysBetween(aISO: string, bISO: string): number {
  const a = new Date(aISO + "T00:00:00Z").getTime();
  const b = new Date(bISO + "T00:00:00Z").getTime();
  return Math.round((b - a) / (1000 * 60 * 60 * 24));
}

function humanDate(iso: string): string {
  const [y, m, d] = iso.split("-").map((s) => parseInt(s, 10));
  const dt = new Date(Date.UTC(y, m - 1, d));
  return dt.toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
}

// Thin adapter over the shared Gmail sender, keeping the original call shape.
async function callComposioGmailSend(
  opts: {
    creds: GmailCreds;
    recipient: string;
    subject: string;
    bodyHtml: string;
    cc?: string;
  },
): Promise<{ ok: boolean; error: string | null }> {
  const r = await sendGmail({
    creds: opts.creds,
    to: opts.recipient,
    subject: opts.subject,
    html: opts.bodyHtml,
    cc: opts.cc ? [opts.cc] : undefined,
  });
  return { ok: r.ok, error: r.error };
}

function buildEmailBody(input: {
  firstName: string;
  licenseLabel: string;
  authority: string | null;
  states: string[];
  dueDateISO: string;
  daysOut: number;
  hoursRequired: number | null;
  ceBreakdown: Record<string, number> | null;
  notes: string | null;
  sourceUrl: string | null;
  isPastDue: boolean;
}): { subject: string; html: string } {
  const {
    firstName,
    licenseLabel,
    authority,
    states,
    dueDateISO,
    daysOut,
    hoursRequired,
    ceBreakdown,
    notes,
    sourceUrl,
    isPastDue,
  } = input;

  const stateStr = states && states.length > 0 ? ` (${states.join(", ")})` : "";
  const auth = authority ? ` — ${authority}` : "";
  const dueHuman = humanDate(dueDateISO);

  const status = isPastDue
    ? `⚠️ PAST DUE by ${Math.abs(daysOut)} day${Math.abs(daysOut) === 1 ? "" : "s"}`
    : daysOut === 0
    ? "🔴 DUE TODAY"
    : `${daysOut} day${daysOut === 1 ? "" : "s"} out`;

  const subjectTag = isPastDue
    ? "[PAST DUE]"
    : daysOut <= 7
    ? "[URGENT]"
    : "[Reminder]";
  const subject = `${subjectTag} ${licenseLabel}${stateStr} — due ${dueHuman}`;

  const hoursLine = hoursRequired
    ? `<p style="margin:6px 0"><strong>Hours required:</strong> ${hoursRequired}</p>`
    : "";

  let breakdownLine = "";
  if (ceBreakdown && Object.keys(ceBreakdown).length > 0) {
    const items = Object.entries(ceBreakdown)
      .map(([k, v]) => `<li>${k.replace(/_/g, " ")}: ${v} hrs</li>`)
      .join("");
    breakdownLine =
      `<p style="margin:6px 0"><strong>Breakdown:</strong></p><ul style="margin:4px 0 8px 20px">${items}</ul>`;
  }

  const notesLine = notes
    ? `<p style="margin:12px 0;padding:10px 12px;background:#f6f8fb;border-left:3px solid #4a86e8;font-size:13px;color:#334">${notes}</p>`
    : "";

  const linkLine = sourceUrl
    ? `<p style="margin:6px 0"><a href="${sourceUrl}" style="color:#4a86e8">Open the completion portal →</a></p>`
    : "";

  const html = `<!DOCTYPE html>
<html><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,sans-serif;color:#1a1a1a;max-width:640px;margin:0 auto;padding:24px">
  <div style="border-bottom:2px solid ${
    isPastDue || daysOut === 0 ? "#dc2626" : daysOut <= 14 ? "#ea580c" : "#4a86e8"
  };padding-bottom:12px;margin-bottom:20px">
    <h2 style="margin:0;font-size:20px;font-weight:700">${licenseLabel}${stateStr}${auth}</h2>
    <p style="margin:6px 0 0;font-size:14px;color:#666">Hi ${firstName},</p>
  </div>

  <p style="font-size:16px;margin:0 0 12px">
    <strong style="color:${isPastDue || daysOut === 0 ? "#dc2626" : daysOut <= 14 ? "#ea580c" : "#1a1a1a"}">${status}</strong> — <strong>${dueHuman}</strong>
  </p>

  ${hoursLine}
  ${breakdownLine}
  ${notesLine}
  ${linkLine}

  <p style="margin:24px 0 8px;font-size:13px;color:#666">
    Once you finish this renewal, mark it complete in the Newtworks and the next cycle
    will be scheduled automatically.
  </p>

  <p style="margin:8px 0 0;font-size:12px;color:#999">
    Peter Story State Farm — Newtworks
  </p>
</body></html>`;

  return { subject, html };
}

Deno.serve(async (req: Request) => {
  const invokedAt = new Date().toISOString();
  const startedMs = Date.now();

  let body: any = {};
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ ok: false, error: "invalid json" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const agencyId = body.agency_id || AGENCY_ID_DEFAULT;
  const sharedSecret = body.shared_secret;

  const denied = await requireSharedSecret(agencyId, sharedSecret);
  if (denied) return denied;

  const credsRes = await getComposioGmailCreds(agencyId);
  if (!credsRes.ok) {
    return new Response(
      JSON.stringify({ ok: false, error: credsRes.error }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
  const gmailCreds = credsRes.creds;

  const { data: licenses, error: licenseErr } = await sb
    .from("team_licenses")
    .select(`
      id, team_member_id, license_type, authority, states, due_date,
      cycle_months, initial_issue_date, last_completed_at, status,
      ce_required, hours_required, ce_breakdown, notes, source_url,
      team:team_member_id (
        id, first_name, last_name, is_active, email_personal, email_sf
      )
    `)
    .eq("agency_id", agencyId)
    .eq("status", "active");

  if (licenseErr) {
    return new Response(
      JSON.stringify({ ok: false, error: licenseErr.message }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const today = todayInCT();
  const results: any = {
    processed: 0,
    alerts_upserted: 0,
    emails_sent: 0,
    emails_skipped_already_sent: 0,
    emails_failed: 0,
    skipped_ce_not_required: 0,
    skipped_inactive_member: 0,
    errors: [] as string[],
  };

  for (const r of (licenses ?? [])) {
    results.processed++;

    const teamMember = (r as any).team;
    if (!teamMember || !teamMember.is_active) {
      results.skipped_inactive_member++;
      continue;
    }

    const isCeRow = r.license_type.endsWith("_ce") ||
      r.license_type === "series_6_annual_compliance" ||
      r.license_type === "series_6_regulatory_element";
    if (isCeRow && r.ce_required === false) {
      results.skipped_ce_not_required++;
      continue;
    }

    const daysOut = daysBetween(today, r.due_date);
    const isPastDue = daysOut < 0;
    const severity = severityForDays(daysOut);
    const licenseLabel = labelFor(r.license_type);

    const { data: existingAlert } = await sb
      .from("alerts")
      .select("id, severity")
      .eq("module_reference", "team_licenses")
      .eq("related_id", r.id)
      .eq("is_resolved", false)
      .maybeSingle();

    const alertTitle =
      `${teamMember.first_name} ${teamMember.last_name} — ${licenseLabel}`;
    const alertMessage = isPastDue
      ? `PAST DUE by ${Math.abs(daysOut)} day${Math.abs(daysOut) === 1 ? "" : "s"}. Due ${r.due_date}.`
      : daysOut === 0
      ? `Due TODAY (${r.due_date}).`
      : `Due in ${daysOut} day${daysOut === 1 ? "" : "s"} (${r.due_date}).`;

    if (daysOut <= 90 || existingAlert) {
      if (existingAlert) {
        const { error: updErr } = await sb
          .from("alerts")
          .update({
            severity,
            title: alertTitle,
            message: alertMessage,
            due_date: r.due_date,
          })
          .eq("id", existingAlert.id);
        if (!updErr) results.alerts_upserted++;
      } else {
        const { error: insErr } = await sb.from("alerts").insert({
          agency_id: agencyId,
          alert_type: "renewal_due",
          severity,
          title: alertTitle,
          message: alertMessage,
          module_reference: "team_licenses",
          related_id: r.id,
          is_read: false,
          is_resolved: false,
          due_date: r.due_date,
        });
        if (!insErr) results.alerts_upserted++;
      }
    }

    let cadenceDay: number | null = null;
    if (CADENCE_DAYS_BEFORE.includes(daysOut)) {
      cadenceDay = daysOut;
    } else if (daysOut < 0) {
      cadenceDay = daysOut;
    }

    if (cadenceDay === null) continue;

    const { subject, html } = buildEmailBody({
      firstName: teamMember.first_name,
      licenseLabel,
      authority: r.authority,
      states: r.states || [],
      dueDateISO: r.due_date,
      daysOut,
      hoursRequired: r.hours_required,
      ceBreakdown: r.ce_breakdown,
      notes: r.notes,
      sourceUrl: r.source_url,
      isPastDue,
    });

    const recipients: Array<{ channel: string; email: string }> = [];
    if (teamMember.email_personal) {
      recipients.push({
        channel: "email_personal",
        email: teamMember.email_personal,
      });
    }
    if (teamMember.email_sf) {
      recipients.push({
        channel: "email_sf",
        email: teamMember.email_sf,
      });
    }

    const ccPeter =
      (severity === "high" || severity === "critical") &&
      teamMember.email_personal !== OWNER_EMAIL;

    for (const rc of recipients) {
      const { data: logHit } = await sb
        .from("license_notification_log")
        .select("id")
        .eq("team_license_id", r.id)
        .eq("cadence_day", cadenceDay)
        .eq("channel", rc.channel)
        .maybeSingle();

      if (logHit) {
        results.emails_skipped_already_sent++;
        continue;
      }

      const sendResult = await callComposioGmailSend({
        creds: gmailCreds,
        recipient: rc.email,
        subject,
        bodyHtml: html,
        cc: ccPeter ? OWNER_EMAIL : undefined,
      });

      const { error: logErr } = await sb
        .from("license_notification_log")
        .insert({
          agency_id: agencyId,
          team_license_id: r.id,
          cadence_day: cadenceDay,
          channel: rc.channel,
          recipient: rc.email,
          status: sendResult.ok ? "sent" : "failed",
          error: sendResult.error,
        });

      if (sendResult.ok) {
        results.emails_sent++;
      } else {
        results.emails_failed++;
        results.errors.push(
          `${rc.channel} to ${rc.email} for ${r.id}: ${sendResult.error}`,
        );
      }
      if (logErr) {
        results.errors.push(
          `log insert failed for ${r.id}/${rc.channel}: ${logErr.message}`,
        );
      }
    }
  }

  const durationSec = Math.round((Date.now() - startedMs) / 100) / 10;

  return new Response(
    JSON.stringify({
      ok: true,
      invoked_at: invokedAt,
      duration_seconds: durationSec,
      today_ct: today,
      ...results,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});
