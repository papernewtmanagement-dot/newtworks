// =========================================================================
// renewal-reminder-runner
// =========================================================================
// Daily job that:
//   1) Reads active rows from public.team_renewals
//   2) Upserts an alerts row per renewal (severity scales with days_until_due)
//   3) On cadence days (90/60/30/14/7/1/0 or negative for past-due) sends a
//      reminder email to the team member's email_personal AND email_sf, cc
//      Peter for high/critical. Skips CE reminders where ce_required=false.
//   4) Logs each send to renewal_notification_log so we don't double-send.
//
// Invoked by pg_cron via dispatch_renewal_reminders() (see companion SQL).
// =========================================================================

// deno-lint-ignore-file no-explicit-any
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";
const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";
const OWNER_EMAIL = "storypeterj@gmail.com";
const TZ = "America/Chicago";

const CADENCE_DAYS_BEFORE = [90, 60, 30, 14, 7, 1, 0];

const RENEWAL_LABELS: Record<string, string> = {
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
  return RENEWAL_LABELS[t] ?? t;
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

async function callComposioGmailSend(
  opts: {
    apiKey: string;
    userId: string;
    connectedAccountId: string;
    recipient: string;
    subject: string;
    bodyHtml: string;
    cc?: string;
  },
): Promise<{ ok: boolean; error: string | null }> {
  const args: Record<string, any> = {
    recipient_email: opts.recipient,
    subject: opts.subject,
    body: opts.bodyHtml,
    is_html: true,
    user_id: "me",
  };
  if (opts.cc) args.cc = [opts.cc];

  const res = await fetch(`${COMPOSIO_BASE}/GMAIL_SEND_EMAIL`, {
    method: "POST",
    headers: {
      "x-api-key": opts.apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      user_id: opts.userId,
      connected_account_id: opts.connectedAccountId,
      arguments: args,
    }),
  });
  const text = await res.text();
  let parsed: any = {};
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = { raw: text };
  }
  const ok = res.ok && !!parsed?.successful;
  const error = ok
    ? null
    : (parsed?.error?.message || parsed?.error || text.slice(0, 300));
  return { ok, error };
}

function buildEmailBody(input: {
  firstName: string;
  renewalLabel: string;
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
    renewalLabel,
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
  const subject = `${subjectTag} ${renewalLabel}${stateStr} — due ${dueHuman}`;

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
    <h2 style="margin:0;font-size:20px;font-weight:700">${renewalLabel}${stateStr}${auth}</h2>
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
    Once you finish this renewal, mark it complete in the BCC and the next cycle
    will be scheduled automatically.
  </p>

  <p style="margin:8px 0 0;font-size:12px;color:#999">
    Peter Story State Farm — Business Command Center
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

  const agencyId = body.agency_id || AGENCY_ID;
  const sharedSecret = body.shared_secret;

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const sb = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  const { data: secretRow } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", "automation_runner_cron_secret")
    .maybeSingle();

  if (!secretRow || secretRow.setting_value !== sharedSecret) {
    return new Response(JSON.stringify({ ok: false, error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const { data: settingsRows } = await sb
    .from("settings")
    .select("setting_key,setting_value")
    .eq("agency_id", agencyId)
    .in("setting_key", [
      "composio_api_key",
      "composio_user_id",
      "composio_gmail_account_id",
    ]);
  const settingsMap = Object.fromEntries(
    (settingsRows ?? []).map((r: any) => [r.setting_key, r.setting_value]),
  );
  const composioApiKey = settingsMap["composio_api_key"];
  const composioUserId = settingsMap["composio_user_id"];
  const composioGmailAccountId = settingsMap["composio_gmail_account_id"];

  if (!composioApiKey || !composioUserId || !composioGmailAccountId) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "Composio Gmail credentials missing from settings",
      }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const { data: renewals, error: renewalErr } = await sb
    .from("team_renewals")
    .select(`
      id, team_member_id, renewal_type, authority, states, due_date,
      cycle_months, initial_issue_date, last_completed_at, status,
      ce_required, hours_required, ce_breakdown, notes, source_url,
      team:team_member_id (
        id, first_name, last_name, is_active, email_personal, email_sf
      )
    `)
    .eq("agency_id", agencyId)
    .eq("status", "active");

  if (renewalErr) {
    return new Response(
      JSON.stringify({ ok: false, error: renewalErr.message }),
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

  for (const r of (renewals ?? [])) {
    results.processed++;

    const teamMember = (r as any).team;
    if (!teamMember || !teamMember.is_active) {
      results.skipped_inactive_member++;
      continue;
    }

    const isCeRow = r.renewal_type.endsWith("_ce") ||
      r.renewal_type === "series_6_annual_compliance" ||
      r.renewal_type === "series_6_regulatory_element";
    if (isCeRow && r.ce_required === false) {
      results.skipped_ce_not_required++;
      continue;
    }

    const daysOut = daysBetween(today, r.due_date);
    const isPastDue = daysOut < 0;
    const severity = severityForDays(daysOut);
    const renewalLabel = labelFor(r.renewal_type);

    const { data: existingAlert } = await sb
      .from("alerts")
      .select("id, severity")
      .eq("module_reference", "team_renewals")
      .eq("related_id", r.id)
      .eq("is_resolved", false)
      .maybeSingle();

    const alertTitle =
      `${teamMember.first_name} ${teamMember.last_name} — ${renewalLabel}`;
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
          module_reference: "team_renewals",
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
      renewalLabel,
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
        .from("renewal_notification_log")
        .select("id")
        .eq("team_renewal_id", r.id)
        .eq("cadence_day", cadenceDay)
        .eq("channel", rc.channel)
        .maybeSingle();

      if (logHit) {
        results.emails_skipped_already_sent++;
        continue;
      }

      const sendResult = await callComposioGmailSend({
        apiKey: composioApiKey,
        userId: composioUserId,
        connectedAccountId: composioGmailAccountId,
        recipient: rc.email,
        subject,
        bodyHtml: html,
        cc: ccPeter ? OWNER_EMAIL : undefined,
      });

      const { error: logErr } = await sb
        .from("renewal_notification_log")
        .insert({
          agency_id: agencyId,
          team_renewal_id: r.id,
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
