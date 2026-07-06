// terminate-team-member edge function (v1)
//
// Orchestrates a State Farm team-member termination:
//   1. Loads the team member + the "Termination" admin_pages checklist.
//   2. Composes an HTML notification email with identity, contact (incl. physical
//      address), SF identifiers (alias + ext), and the verbatim AAO checklist
//      pre-filled with name/alias/extension.
//   3. Updates team: archived_at, end_date, is_active=false, termination_reason,
//      final_paycheck_date.
//   4. Deactivates the linked users row if present.
//   5. Sets both team_telegram_map.is_excluded_pjsagencybot=true AND is_excluded_paper_newt_bot=true (excluded_reason='terminated').
//   6. Strips the person's block from the "Team List" processes page.
//   7. Sends the email to Peter's State Farm address via Composio Gmail.
//   8. Kicks the user from the team Telegram group (ban + unban → no permanent
//      ban list).
//   9. Logs everything to automation_run_log; failures land in alerts so Peter
//      can see + retry.
//
// Email + Telegram are best-effort: the DB state is the source of truth for
// whether the termination happened. External failures create alerts but do
// not roll back the archive.

// deno-lint-ignore-file no-explicit-any
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";
const COMPOSIO_GMAIL_URL = "https://backend.composio.dev/api/v3/tools/execute/GMAIL_SEND_EMAIL";
const NOTICE_RECIPIENT = "peter.story.yrru@statefarm.com";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function getSetting(key: string): Promise<string | null> {
  const { data, error } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", AGENCY_ID)
    .eq("setting_key", key)
    .maybeSingle();
  if (error) throw new Error(`settings.${key}: ${error.message}`);
  return data?.setting_value ?? null;
}

function htmlEscape(s: string | null | undefined): string {
  if (s === null || s === undefined) return "";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function fmtDate(d: string | null | undefined): string {
  if (!d) return "—";
  try {
    const dt = new Date(d.length === 10 ? d + "T00:00:00" : d);
    return dt.toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" });
  } catch {
    return d;
  }
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Convert the small markdown subset used in admin_pages → HTML.
// Supports: list bullets (- item), bold (**x**), italics (*x* / _x_),
// inline links [text](url), and paragraph breaks. No nested lists.
function checklistMdToHtml(md: string): string {
  const lines = md.split("\n");
  const out: string[] = [];
  let inList = false;
  for (const raw of lines) {
    const line = raw.trim();
    if (line === "---" || line === "") {
      if (inList) { out.push("</ul>"); inList = false; }
      continue;
    }
    const bullet = line.match(/^[-*]\s+(.*)$/);
    if (bullet) {
      if (!inList) { out.push("<ul style='margin:0 0 8px 18px;padding:0;line-height:1.55;'>"); inList = true; }
      out.push(`<li>${inlineFmt(bullet[1])}</li>`);
      continue;
    }
    if (inList) { out.push("</ul>"); inList = false; }
    out.push(`<p style='margin:6px 0;line-height:1.55;'>${inlineFmt(line)}</p>`);
  }
  if (inList) out.push("</ul>");
  return out.join("\n");
}
function inlineFmt(s: string): string {
  let out = htmlEscape(s);
  out = out.replace(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g, '<a href="$2" style="color:#0b5394;">$1</a>');
  out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  out = out.replace(/(?<!\*)\*([^*]+)\*(?!\*)/g, "<em>$1</em>");
  out = out.replace(/_([^_]+)_/g, "<em>$1</em>");
  return out;
}

interface TerminateBody {
  team_id: string;
  termination_date: string;
  termination_reason: string;
  reason_category?: string | null;
  final_paycheck_date?: string | null;
}

async function logAlert(severity: string, title: string, message: string): Promise<void> {
  try {
    await sb.from("alerts").insert({
      agency_id: AGENCY_ID,
      alert_type: "termination_partial_failure",
      severity,
      title,
      message,
      module_reference: "hr_people",
      is_resolved: false,
    });
  } catch (e) {
    console.error("logAlert failed:", e);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let body: TerminateBody;
  try { body = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }

  if (!body.team_id || !body.termination_date || !body.termination_reason) {
    return json({ error: "team_id, termination_date, termination_reason are required" }, 400);
  }

  const runStarted = new Date();
  const auditLog: string[] = [];
  const warnings: string[] = [];

  try {
    // 1) Load member
    const { data: member, error: memErr } = await sb.from("team")
      .select("id, user_id, first_name, last_name, nickname, role, role_level, role_category, employment_type, hire_date, start_date, sf_alias, phone_extension, email_personal, email_sf, phone_personal, address_line1, address_line2, city, state, zip_code, archived_at")
      .eq("id", body.team_id)
      .eq("agency_id", AGENCY_ID)
      .maybeSingle();
    if (memErr) return json({ error: `team lookup: ${memErr.message}` }, 500);
    if (!member) return json({ error: "team member not found" }, 404);
    if (member.archived_at) return json({ error: `already archived at ${member.archived_at}` }, 409);
    const fullName = `${member.first_name} ${member.last_name}`;
    auditLog.push(`Loaded ${fullName}`);

    // 2) Load termination checklist
    const { data: termPage } = await sb.from("admin_pages")
      .select("content")
      .eq("agency_id", AGENCY_ID)
      .eq("title", "Termination")
      .eq("is_active", true)
      .maybeSingle();
    let checklistMd = termPage?.content || "(Termination checklist not found in admin_pages.)";
    // Pre-fill the AAO request-details placeholders with the actual values.
    const aliasFill = member.sf_alias || "(no alias on file)";
    const extFill = member.phone_extension || "(no extension on file)";
    checklistMd = checklistMd
      .replace(/Who is being removed/gi, `Who is being removed → **${fullName}**`)
      .replace(/^\s*-\s+Alias\s*$/gim, `- Alias → **${aliasFill}**`)
      .replace(/^\s*-\s+Old extension(.*)$/gim, `- Old extension → **${extFill}**`);
    auditLog.push("Loaded + pre-filled termination checklist");

    // 3) Compose email body
    const addressLines: string[] = [];
    if (member.address_line1) addressLines.push(htmlEscape(member.address_line1));
    if (member.address_line2) addressLines.push(htmlEscape(member.address_line2));
    const cityStateZip = [
      member.city,
      [member.state, member.zip_code].filter(Boolean).join(" "),
    ].filter(Boolean).join(", ");
    if (cityStateZip) addressLines.push(htmlEscape(cityStateZip));
    const addressHtml = addressLines.length > 0
      ? addressLines.join("<br>")
      : "<em style='color:#999;'>[not on file]</em>";

    const dateForSubject = new Date(body.termination_date + "T00:00:00").toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
    const subject = `[Termination] ${fullName} — ${dateForSubject}`;

    const html = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>${htmlEscape(subject)}</title></head>
<body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#222;max-width:680px;margin:0 auto;padding:24px;background:#fafafa;">

<div style="background:#fff;border-radius:8px;padding:24px;box-shadow:0 1px 3px rgba(0,0,0,0.06);">

<h2 style="color:#a00;margin:0 0 4px 0;font-size:22px;">Team Member Termination</h2>
<p style="color:#666;margin:0 0 24px 0;font-size:13px;">Termination notice for <strong>${htmlEscape(fullName)}</strong> — effective ${htmlEscape(fmtDate(body.termination_date))}.</p>

<h3 style="border-bottom:2px solid #a00;padding-bottom:4px;font-size:14px;margin-top:0;">Identity</h3>
<table cellpadding="6" style="border-collapse:collapse;width:100%;font-size:13px;">
<tr><td style="width:180px;color:#666;">Name</td><td>${htmlEscape(fullName)}${member.nickname ? ` (${htmlEscape(member.nickname)})` : ""}</td></tr>
<tr><td style="color:#666;">Role</td><td>${htmlEscape(member.role || "—")}${member.role_level ? ` — ${htmlEscape(member.role_level)}` : ""}${member.role_category ? ` (${htmlEscape(member.role_category)})` : ""}</td></tr>
<tr><td style="color:#666;">Employment Type</td><td>${htmlEscape(member.employment_type || "—")}</td></tr>
<tr><td style="color:#666;">Hire Date</td><td>${htmlEscape(fmtDate(member.hire_date || member.start_date))}</td></tr>
<tr><td style="color:#666;">Termination Date</td><td><strong>${htmlEscape(fmtDate(body.termination_date))}</strong></td></tr>
${body.final_paycheck_date ? `<tr><td style="color:#666;">Final Paycheck Date</td><td>${htmlEscape(fmtDate(body.final_paycheck_date))}</td></tr>` : ""}
${body.reason_category ? `<tr><td style="color:#666;">Reason Category</td><td>${htmlEscape(body.reason_category)}</td></tr>` : ""}
<tr><td style="color:#666;vertical-align:top;">Reason / Notes</td><td style="white-space:pre-wrap;">${htmlEscape(body.termination_reason)}</td></tr>
</table>

<h3 style="border-bottom:2px solid #a00;padding-bottom:4px;font-size:14px;margin-top:24px;">Personal Contact</h3>
<table cellpadding="6" style="border-collapse:collapse;width:100%;font-size:13px;">
<tr><td style="width:180px;color:#666;vertical-align:top;">Personal Email</td><td>${member.email_personal ? `<a href="mailto:${htmlEscape(member.email_personal)}" style="color:#0b5394;">${htmlEscape(member.email_personal)}</a>` : "<em style='color:#999;'>[not on file]</em>"}</td></tr>
<tr><td style="color:#666;vertical-align:top;">Personal Phone</td><td>${member.phone_personal ? htmlEscape(member.phone_personal) : "<em style='color:#999;'>[not on file]</em>"}</td></tr>
<tr><td style="color:#666;vertical-align:top;">Physical Address</td><td>${addressHtml}</td></tr>
</table>

<h3 style="border-bottom:2px solid #a00;padding-bottom:4px;font-size:14px;margin-top:24px;">State Farm Identifiers</h3>
<table cellpadding="6" style="border-collapse:collapse;width:100%;font-size:13px;">
<tr><td style="width:180px;color:#666;">SF Alias</td><td><strong>${member.sf_alias ? htmlEscape(member.sf_alias) : "<em style='color:#999;'>[not on file]</em>"}</strong></td></tr>
<tr><td style="color:#666;">Phone Extension</td><td>${member.phone_extension ? htmlEscape(member.phone_extension) : "<em style='color:#999;'>[not on file]</em>"}</td></tr>
<tr><td style="color:#666;">SF Email</td><td>${member.email_sf ? htmlEscape(member.email_sf) : "<em style='color:#999;'>[not on file]</em>"}</td></tr>
</table>

<h3 style="border-bottom:2px solid #a00;padding-bottom:4px;font-size:14px;margin-top:24px;">Termination Checklist (from admin_pages)</h3>
<div style="background:#f7f7f7;padding:14px 18px;border-left:4px solid #a00;border-radius:4px;font-size:13px;">
${checklistMdToHtml(checklistMd)}
</div>

<h3 style="border-bottom:2px solid #a00;padding-bottom:4px;font-size:14px;margin-top:24px;">Newtworks Automated Actions</h3>
<ul style="line-height:1.7;font-size:13px;margin:8px 0 0 0;padding-left:20px;">
<li>Archived in Newtworks database (<code>team.archived_at</code>)</li>
<li>Linked user login deactivated (if any)</li>
<li>Stripped from the Team List page in Processes</li>
<li>Excluded from both Telegram bots (<code>team_telegram_map.is_excluded_pjsagencybot=true, is_excluded_paper_newt_bot=true</code>)</li>
<li>Kicked from the team Telegram group</li>
</ul>

<p style="color:#999;margin-top:32px;font-size:11px;border-top:1px solid #ddd;padding-top:14px;">
Sent by the Newtworks on ${new Date().toLocaleString("en-US", { timeZone: "America/Chicago", dateStyle: "full", timeStyle: "short" })} CT.
</p>

</div>
</body></html>`;
    auditLog.push(`Composed email (${html.length} chars)`);

    // 4) Update team row
    const nowIso = new Date().toISOString();
    const { error: teamErr, data: teamUpd } = await sb.from("team").update({
      archived_at: nowIso,
      end_date: body.termination_date,
      is_active: false,
      termination_reason: body.termination_reason,
      final_paycheck_date: body.final_paycheck_date || null,
      updated_at: nowIso,
    }).eq("id", body.team_id).eq("agency_id", AGENCY_ID).select("id");
    if (teamErr) return json({ error: `team update: ${teamErr.message}`, audit_log: auditLog }, 500);
    if (!teamUpd || teamUpd.length === 0) {
      return json({ error: "team update affected 0 rows (RLS?)", audit_log: auditLog }, 500);
    }
    auditLog.push("Updated team row");

    // 5) Deactivate linked user
    if (member.user_id) {
      const { error: usrErr } = await sb.from("users").update({
        is_active: false,
        invite_status: "deactivated",
        updated_at: nowIso,
      }).eq("id", member.user_id).eq("agency_id", AGENCY_ID);
      if (usrErr) warnings.push(`users update: ${usrErr.message}`);
      else auditLog.push("Deactivated linked user");
    }

    // 6) Telegram map: mark excluded
    const { error: tgmErr, data: tgm } = await sb.from("team_telegram_map")
      .update({ is_excluded_pjsagencybot: true, is_excluded_paper_newt_bot: true, excluded_reason: "terminated", updated_at: nowIso })
      .eq("team_id", body.team_id)
      .eq("agency_id", AGENCY_ID)
      .select("telegram_user_id")
      .maybeSingle();
    if (tgmErr) warnings.push(`telegram map: ${tgmErr.message}`);
    else if (tgm) auditLog.push("team_telegram_map.is_excluded_pjsagencybot=true, is_excluded_paper_newt_bot=true");
    const telegramUserId: number | null = tgm?.telegram_user_id ?? null;

    // 7) Strip from "Team List" processes page (best-effort)
    try {
      const { data: pages, error: pbErr } = await sb.from("processes")
        .select("id, content")
        .eq("agency_id", AGENCY_ID)
        .eq("title", "Team List")
        .limit(1);
      if (pbErr) warnings.push(`processes lookup: ${pbErr.message}`);
      else if (pages && pages.length > 0) {
        const page = pages[0];
        const original: string = page.content || "";
        const nameRe = new RegExp(
          `(^|\\n\\n)${escapeRegex(member.first_name)}\\s+${escapeRegex(member.last_name)}\\s*\\n(?:[ \\t]*-[^\\n]*\\n?)+`,
          "gi"
        );
        let next = original.replace(nameRe, (_match, lead) => lead || "");
        next = next.replace(/\n{3,}/g, "\n\n").replace(/\s+$/, "") + "\n";
        if (next !== original) {
          const { error: upErr } = await sb.from("processes").update({
            content: next,
            updated_at: nowIso,
          }).eq("id", page.id);
          if (upErr) warnings.push(`processes update: ${upErr.message}`);
          else auditLog.push("Stripped from Team List processes page");
        } else {
          warnings.push(`Could not locate ${fullName}'s block in Team List page`);
        }
      } else {
        warnings.push("Team List processes page not found");
      }
    } catch (e) {
      warnings.push(`processes strip exception: ${e instanceof Error ? e.message : String(e)}`);
    }

    // 8) Send email via Composio Gmail (best-effort)
    let emailSent = false;
    let emailErrMsg: string | null = null;
    try {
      const apiKey = await getSetting("composio_api_key");
      const userId = await getSetting("composio_user_id");
      const connId = await getSetting("composio_gmail_account_id");
      if (!apiKey || !userId || !connId) {
        emailErrMsg = "Composio Gmail config missing in settings";
      } else {
        const res = await fetch(COMPOSIO_GMAIL_URL, {
          method: "POST",
          headers: { "x-api-key": apiKey, "Content-Type": "application/json" },
          body: JSON.stringify({
            user_id: userId,
            connected_account_id: connId,
            arguments: {
              recipient_email: NOTICE_RECIPIENT,
              subject,
              body: html,
              is_html: true,
            },
          }),
        });
        const text = await res.text();
        if (!res.ok) {
          emailErrMsg = `Composio HTTP ${res.status}: ${text.slice(0, 400)}`;
        } else {
          emailSent = true;
          auditLog.push(`Email sent to ${NOTICE_RECIPIENT}`);
        }
      }
    } catch (e) {
      emailErrMsg = `email send exception: ${e instanceof Error ? e.message : String(e)}`;
    }
    if (!emailSent && emailErrMsg) {
      warnings.push(emailErrMsg);
      await logAlert("warning", `Termination email failed for ${fullName}`,
        `${emailErrMsg}\n\nSubject: ${subject}\n\nThe team row + Telegram exclusion were applied. The email did NOT deliver — manual notification needed.`);
    }

    // 9) Kick from Telegram group (best-effort)
    let telegramKicked = false;
    let telegramErrMsg: string | null = null;
    if (telegramUserId) {
      try {
        const chatIdStr = await getSetting("telegram_team_group_chat_id");
        const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
        const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
        if (!chatIdStr) {
          telegramErrMsg = "telegram_team_group_chat_id not set in settings";
        } else {
          const chatId = parseInt(chatIdStr, 10);
          const banRes = await fetch(`${supabaseUrl}/functions/v1/telegram`, {
            method: "POST",
            headers: {
              "Authorization": `Bearer ${serviceKey}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              action: "banChatMember",
              chat_id: chatId,
              user_id: telegramUserId,
            }),
          });
          const banJson = await banRes.json().catch(() => ({}));
          if (!banRes.ok || banJson?.ok === false) {
            telegramErrMsg = `ban failed: ${JSON.stringify(banJson).slice(0, 300)}`;
          } else {
            // Immediately unban → removes the permanent ban so they could rejoin
            // later via fresh invite if needed. This is Telegram's "kick" idiom.
            await fetch(`${supabaseUrl}/functions/v1/telegram`, {
              method: "POST",
              headers: {
                "Authorization": `Bearer ${serviceKey}`,
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                action: "unbanChatMember",
                chat_id: chatId,
                user_id: telegramUserId,
                only_if_banned: true,
              }),
            });
            telegramKicked = true;
            auditLog.push(`Kicked tg user ${telegramUserId} from group ${chatId}`);
          }
        }
      } catch (e) {
        telegramErrMsg = `telegram kick exception: ${e instanceof Error ? e.message : String(e)}`;
      }
    } else {
      auditLog.push("No telegram_user_id on file — Telegram kick skipped");
    }
    if (telegramErrMsg) {
      warnings.push(telegramErrMsg);
      await logAlert("warning", `Telegram kick failed for ${fullName}`,
        `${telegramErrMsg}\n\nTelegram user ID: ${telegramUserId}\n\nThe team row is archived. Manually remove them from the group via Telegram client if needed.`);
    }

    // 10) Log to automation_run_log
    const durationSec = Math.max(1, Math.round((Date.now() - runStarted.getTime()) / 1000));
    const status = warnings.length === 0 ? "success" : "partial_success";
    await sb.from("automation_run_log").insert({
      agency_id: AGENCY_ID,
      recipe_id: null,
      run_at: runStarted.toISOString(),
      status,
      output_summary: `Terminated ${fullName} effective ${body.termination_date}. ` +
        `Audit: ${auditLog.join("; ")}.` +
        (warnings.length > 0 ? ` Warnings: ${warnings.join("; ")}.` : ""),
      duration_seconds: durationSec,
    });

    return json({
      success: true,
      team_id: body.team_id,
      name: fullName,
      termination_date: body.termination_date,
      email_sent: emailSent,
      telegram_kicked: telegramKicked,
      audit_log: auditLog,
      warnings,
    });
  } catch (e) {
    const errMsg = e instanceof Error ? e.message : String(e);
    const durationSec = Math.max(1, Math.round((Date.now() - runStarted.getTime()) / 1000));
    await sb.from("automation_run_log").insert({
      agency_id: AGENCY_ID,
      recipe_id: null,
      run_at: runStarted.toISOString(),
      status: "failed",
      output_summary: `terminate-team-member fatal: ${errMsg}. Partial audit: ${auditLog.join("; ")}`,
      duration_seconds: durationSec,
      error_message: errMsg,
    });
    return json({ error: errMsg, audit_log: auditLog }, 500);
  }
});
