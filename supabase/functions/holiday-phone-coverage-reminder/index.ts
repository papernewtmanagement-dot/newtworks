// =========================================================================
// holiday-phone-coverage-reminder
// =========================================================================
// Weekly job (Monday mornings): looks at company_holidays for any
// observance='closed' holiday landing on a weekday in the next 7 days.
// If found, emails the active team the "Office Hours" section of the
// Hours & Time Off handbook page (pulled live from public.manuals, not
// hardcoded, so it stays in sync if the handbook changes).
//
// Guards against double-send with company_holidays.phone_coverage_reminder_sent_at
// (set after a successful pass over that holiday).
//
// Invoked by pg_cron via automation-runner's dispatch_ path (see companion
// automation_recipes row "Weekly Holiday Phone Coverage Reminder").
// =========================================================================

// deno-lint-ignore-file no-explicit-any
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { sb, AGENCY_ID_DEFAULT } from "../_shared/supabase.ts";
import { requireSharedSecret } from "../_shared/auth.ts";
import { getComposioGmailCreds, sendGmail, GmailCreds } from "../_shared/gmail.ts";

const TZ = "America/Chicago";

function todayInCT(): string {
  const now = new Date();
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(now);
  const y = parts.find((p) => p.type === "year")!.value;
  const m = parts.find((p) => p.type === "month")!.value;
  const d = parts.find((p) => p.type === "day")!.value;
  return `${y}-${m}-${d}`;
}

function addDaysISO(iso: string, days: number): string {
  const [y, m, d] = iso.split("-").map((s) => parseInt(s, 10));
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() + days);
  return dt.toISOString().slice(0, 10);
}

function isWeekday(iso: string): boolean {
  const [y, m, d] = iso.split("-").map((s) => parseInt(s, 10));
  const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  return dow >= 1 && dow <= 5;
}

function humanDate(iso: string): string {
  const [y, m, d] = iso.split("-").map((s) => parseInt(s, 10));
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-US", {
    weekday: "long", year: "numeric", month: "long", day: "numeric", timeZone: "UTC",
  });
}

function extractOfficeHoursSection(fullContent: string): string {
  const startMarker = "## Office Hours";
  const start = fullContent.indexOf(startMarker);
  if (start === -1) return fullContent.slice(0, 1200);
  const rest = fullContent.slice(start + startMarker.length);
  const nextHeaderIdx = rest.indexOf("\n## ");
  const section = nextHeaderIdx === -1 ? rest : rest.slice(0, nextHeaderIdx);
  return section.trim();
}

function mdToHtmlLite(md: string): string {
  const escaped = md
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const withBold = escaped.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  const lines = withBold.split("\n");
  let html = "";
  let inList = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith("- ")) {
      if (!inList) { html += "<ul>"; inList = true; }
      html += `<li>${trimmed.slice(2)}</li>`;
    } else {
      if (inList) { html += "</ul>"; inList = false; }
      if (trimmed.length > 0) html += `<p>${trimmed}</p>`;
    }
  }
  if (inList) html += "</ul>";
  return html;
}

Deno.serve(async (req: Request) => {
  const invokedAt = new Date().toISOString();
  const startedMs = Date.now();

  let body: any = {};
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ ok: false, error: "invalid json" }), {
      status: 400, headers: { "Content-Type": "application/json" },
    });
  }

  const agencyId = body.agency_id || AGENCY_ID_DEFAULT;
  const sharedSecret = body.shared_secret;
  const denied = await requireSharedSecret(agencyId, sharedSecret);
  if (denied) return denied;

  const today = todayInCT();
  const weekOut = addDaysISO(today, 7);

  const { data: holidays, error: holidayErr } = await sb
    .from("company_holidays")
    .select("id, holiday_name, holiday_date, observance, is_active, phone_coverage_reminder_sent_at")
    .eq("agency_id", agencyId)
    .eq("is_active", true)
    .eq("observance", "closed")
    .is("phone_coverage_reminder_sent_at", null)
    .gte("holiday_date", today)
    .lte("holiday_date", weekOut);

  if (holidayErr) {
    return new Response(JSON.stringify({ ok: false, error: holidayErr.message }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }

  const upcoming = (holidays ?? []).filter((h: any) => isWeekday(h.holiday_date));

  if (upcoming.length === 0) {
    return new Response(JSON.stringify({
      ok: true, invoked_at: invokedAt, records_processed: 0,
      output_summary: "No closed-observance holiday landing on a weekday in the next 7 days.",
    }), { status: 200, headers: { "Content-Type": "application/json" } });
  }

  const credsRes = await getComposioGmailCreds(agencyId);
  if (!credsRes.ok) {
    return new Response(JSON.stringify({ ok: false, error: credsRes.error }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
  const gmailCreds: GmailCreds = credsRes.creds;

  const { data: manualRow, error: manualErr } = await sb
    .from("manuals")
    .select("content")
    .eq("title", "Hours & Time Off")
    .limit(1)
    .maybeSingle();
  if (manualErr || !manualRow) {
    return new Response(JSON.stringify({ ok: false, error: manualErr?.message ?? "Hours & Time Off manual page not found" }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
  const officeHoursSection = extractOfficeHoursSection((manualRow as any).content as string);
  const officeHoursHtml = mdToHtmlLite(officeHoursSection);

  const { data: team, error: teamErr } = await sb
    .from("team")
    .select("id, first_name, email_sf, email_personal, is_active, is_test_user")
    .eq("agency_id", agencyId)
    .eq("is_active", true);
  if (teamErr) {
    return new Response(JSON.stringify({ ok: false, error: teamErr.message }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
  const recipients = (team ?? [])
    .filter((t: any) => t.is_test_user !== true)
    .map((t: any) => ({ name: t.first_name, email: t.email_sf || t.email_personal }))
    .filter((r: any) => !!r.email);

  const results: any = {
    holidays_processed: 0, emails_sent: 0, emails_failed: 0, errors: [] as string[],
  };

  for (const h of upcoming) {
    const dateStr = humanDate((h as any).holiday_date);
    const subject = `Reminder: Office Closed ${humanDate((h as any).holiday_date)} (${(h as any).holiday_name})`;
    const html = `<html><body>
<p>Quick reminder — <strong>${dateStr}</strong> is ${(h as any).holiday_name}. Per the handbook:</p>
${officeHoursHtml}
<p>— Newtworks</p>
</body></html>`;

    let holidaySent = 0;
    let holidayFailed = 0;
    for (const r of recipients) {
      const sendResult = await sendGmail({ creds: gmailCreds, to: r.email, subject, html });
      if (sendResult.ok) { results.emails_sent++; holidaySent++; }
      else {
        results.emails_failed++; holidayFailed++;
        results.errors.push(`${r.email} for ${(h as any).holiday_name}: ${sendResult.error}`);
      }
    }

    if (holidaySent > 0) {
      await sb.from("company_holidays")
        .update({ phone_coverage_reminder_sent_at: new Date().toISOString() })
        .eq("id", (h as any).id);
    }
    results.holidays_processed++;
  }

  const durationSec = Math.round((Date.now() - startedMs) / 100) / 10;
  return new Response(JSON.stringify({
    ok: true, invoked_at: invokedAt, duration_seconds: durationSec, today_ct: today,
    records_processed: results.holidays_processed, ...results,
  }), { status: 200, headers: { "Content-Type": "application/json" } });
});
