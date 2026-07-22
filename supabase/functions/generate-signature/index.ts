// =========================================================================
// generate-signature edge function
// =========================================================================
// Generates a per-team-member State Farm email signature package and emails
// it to the team member's SF alias from paper.newt.management@gmail.com via
// Composio Gmail. Peter is CC'd on every send.
//
// Called two ways:
//   1. RPC send_signature_email(team_member_id, force) → shared_secret +
//      net.http_post (both auto-trigger and manual button)
//   2. Direct POST for testing/dry-run
//
// AUTH: POST body must include shared_secret matching the agency's
// automation_runner_cron_secret setting.
//
// OUTPUT: ZIP attachment with structure:
//   State Farm email.htm            <- tokenized template with per-person subs
//   State Farm email_files/
//     agentPhoto.jpg                <- their photo (resized to 120x147)
//     header_logo.gif, social*.gif, spacer.gif, ...  <- 12 shared GIFs
//     filelist-email.xml            <- Outlook signature manifest
//
// HARD RULE: NO Newtworks self-attribution footer anywhere in the email
// or attachment.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import JSZip from "https://esm.sh/jszip@3.10.1";
import { Image } from "https://deno.land/x/imagescript@1.2.17/mod.ts";
import { SHARED_ASSETS } from "./shared_assets.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const sb: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";
const PETER_CC = "storypeterj@gmail.com";
const PHOTO_W = 120;
const PHOTO_H = 147;

// =========================================================================
// Utilities
// =========================================================================
function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function getSetting(agencyId: string, key: string): Promise<string | null> {
  const { data } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  return data?.setting_value ?? null;
}

// Convert Uint8Array to base64 without stack-blowing large buffers
function bytesToBase64(bytes: Uint8Array): string {
  let bin = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(bin);
}

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// =========================================================================
// Composio Gmail send
// =========================================================================
async function callComposio(opts: {
  apiKey: string;
  userId: string;
  connectedAccountId: string;
  toolSlug: string;
  toolArguments: Record<string, unknown>;
}) {
  const res = await fetch(`${COMPOSIO_BASE}/${opts.toolSlug}`, {
    method: "POST",
    headers: { "x-api-key": opts.apiKey, "Content-Type": "application/json" },
    body: JSON.stringify({
      user_id: opts.userId,
      connected_account_id: opts.connectedAccountId,
      arguments: opts.toolArguments,
    }),
  });
  const text = await res.text();
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = res.ok && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok ? null : (parsed?.error?.message || parsed?.error || text.slice(0, 400));
  return { ok, data, error, httpStatus: res.status };
}

// =========================================================================
// Photo resize — scale-to-fit + center-crop to 120x147
// =========================================================================
async function resizePhotoToBox(input: Uint8Array): Promise<Uint8Array> {
  const img = await Image.decode(input);
  const scale = Math.max(PHOTO_W / img.width, PHOTO_H / img.height);
  const newW = Math.ceil(img.width * scale);
  const newH = Math.ceil(img.height * scale);
  img.resize(newW, newH);
  // Center-crop to exact 120x147
  const cropX = Math.floor((newW - PHOTO_W) / 2);
  const cropY = Math.floor((newH - PHOTO_H) / 2);
  img.crop(cropX, cropY, PHOTO_W, PHOTO_H);
  const out = await img.encodeJPEG(85);
  return out;
}

// =========================================================================
// Token substitution
// =========================================================================
interface TeamMember {
  id: string;
  first_name: string;
  last_name: string;
  email_sf: string;
  photo_storage_path: string | null;
  nmls_number: string | null;
  signature_title: string | null;
  credentials_line: string | null;
  role_level: string | null;
  category: string;
  agency_id: string;
}

function computeTitle(t: TeamMember): string {
  if (t.signature_title && t.signature_title.trim()) return t.signature_title.trim();
  if (t.role_level && t.role_level.trim()) return t.role_level.trim();
  return "";
}

function substituteTemplate(template: string, t: TeamMember): string {
  const fullName = `${t.first_name} ${t.last_name}`.trim();
  const title = computeTitle(t);
  const credInline = t.credentials_line && t.credentials_line.trim()
    ? ` ${t.credentials_line.trim()}`
    : "";
  const nmlsLine = t.nmls_number && t.nmls_number.trim()
    ? `NMLS# ${t.nmls_number.trim()}<br />`
    : "";
  return template
    .replaceAll("{{FULL_NAME}}", fullName)
    .replaceAll("{{TITLE}}", title)
    .replaceAll("{{CREDENTIALS_INLINE}}", credInline)
    .replaceAll("{{NMLS_LINE}}", nmlsLine);
}

// =========================================================================
// Install instructions email body
// =========================================================================
function buildEmailBody(firstName: string): string {
  return `Hi ${firstName},

Attached is your State Farm email signature. Three steps to install:

1. Save the ZIP anywhere, then double-click to unzip. You'll get one file
   called "State Farm email.htm" and one folder called
   "State Farm email_files".

2. Open File Explorer. Click in the address bar at the top, type
   %AppData%\\Roaming\\Microsoft\\Signatures and press Enter. Drag BOTH
   the .htm file and the folder into that window.

3. Open Outlook: File > Options > Mail > Signatures. In the dropdowns on
   the right, set both "New messages" and "Replies/forwards" to "State
   Farm email". Click OK.

Send yourself a test email to check it looks right. If anything's off,
reply to this email and let me know.

— Peter Story State Farm`;
}

// =========================================================================
// ZIP builder
// =========================================================================
async function buildSignatureZip(opts: {
  fullName: string;
  substitutedHtml: string;
  photoJpeg: Uint8Array;
}): Promise<Uint8Array> {
  const zip = new JSZip();
  const rootFolder = zip.folder(`State Farm Templates - ${opts.fullName}`)!;
  rootFolder.file("State Farm email.htm", opts.substitutedHtml);
  const imgFolder = rootFolder.folder("State Farm email_files")!;
  imgFolder.file("agentPhoto.jpg", opts.photoJpeg);
  for (const [filename, b64] of Object.entries(SHARED_ASSETS)) {
    imgFolder.file(filename, base64ToBytes(b64));
  }
  const zipBytes = await zip.generateAsync({ type: "uint8array", compression: "DEFLATE" });
  return zipBytes;
}

// =========================================================================
// Main handler
// =========================================================================
async function run(req: Request): Promise<Response> {
  let body: any = {};
  try { body = await req.json(); }
  catch { return jsonResponse({ ok: false, error: "invalid JSON body" }, 400); }

  const agencyId = body?.agency_id as string;
  const sharedSecret = body?.shared_secret as string;
  const teamMemberId = body?.team_member_id as string;
  const triggeredBy = (body?.triggered_by as string) || "manual"; // 'auto' | 'manual'
  const force = body?.force === true;
  const dryRun = body?.dry_run === true;

  if (!agencyId) return jsonResponse({ ok: false, error: "agency_id required" }, 400);
  if (!teamMemberId) return jsonResponse({ ok: false, error: "team_member_id required" }, 400);

  const expected = await getSetting(agencyId, "automation_runner_cron_secret");
  if (!expected || expected !== sharedSecret) {
    return jsonResponse({ ok: false, error: "auth failed" }, 401);
  }

  // Load Composio credentials
  const composioApiKey = await getSetting(agencyId, "composio_api_key");
  const composioUserId = await getSetting(agencyId, "composio_user_id");
  const gmailAccountId = await getSetting(agencyId, "composio_gmail_account_id");
  if (!composioApiKey || !composioUserId || !gmailAccountId) {
    return jsonResponse({ ok: false, error: "missing composio credentials" }, 400);
  }

  // 1) Load team member
  const { data: member, error: memberErr } = await sb
    .from("team")
    .select("id, first_name, last_name, email_sf, photo_storage_path, nmls_number, signature_title, credentials_line, role_level, category, agency_id, archived_at, is_active")
    .eq("id", teamMemberId)
    .maybeSingle();
  if (memberErr || !member) {
    return jsonResponse({ ok: false, error: `team lookup failed: ${memberErr?.message ?? "not found"}` }, 404);
  }
  if (member.agency_id !== agencyId) {
    return jsonResponse({ ok: false, error: "team member not in this agency" }, 403);
  }
  if (member.category !== "agency") {
    return jsonResponse({ ok: false, error: "signature only sent to category='agency' team members" }, 400);
  }
  if (member.archived_at) {
    return jsonResponse({ ok: false, error: "team member is archived" }, 400);
  }

  // 2) Validation
  const missing: string[] = [];
  if (!member.email_sf) missing.push("email_sf");
  if (!member.photo_storage_path) missing.push("photo_storage_path");
  if (!member.first_name) missing.push("first_name");
  if (!member.last_name) missing.push("last_name");
  if (missing.length > 0) {
    return jsonResponse({ ok: false, error: `missing required fields: ${missing.join(", ")}` }, 400);
  }

  // 3) Skip logic: already-sent check via email_signature_sends
  if (!force) {
    const { data: prior } = await sb
      .from("email_signature_sends")
      .select("id, sent_at")
      .eq("team_member_id", teamMemberId)
      .eq("status", "sent")
      .order("sent_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (prior && triggeredBy === "auto") {
      return jsonResponse({
        ok: true, status: "already_sent",
        prior_send_id: prior.id, sent_at: prior.sent_at,
        note: "Auto-trigger skipped — signature already sent. Pass force=true for manual resend.",
      });
    }
  }

  // 4) Fetch template
  const { data: tpl, error: tplErr } = await sb
    .from("email_signature_template")
    .select("template_html")
    .eq("agency_id", agencyId)
    .maybeSingle();
  if (tplErr || !tpl?.template_html) {
    return jsonResponse({ ok: false, error: `template lookup failed: ${tplErr?.message ?? "not found"}` }, 500);
  }

  // 5) Fetch photo from Storage
  const { data: photoBlob, error: photoErr } = await sb.storage
    .from("email_signatures")
    .download(member.photo_storage_path!);
  if (photoErr || !photoBlob) {
    return jsonResponse({ ok: false, error: `photo download failed: ${photoErr?.message ?? "not found"}` }, 500);
  }
  const photoBytes = new Uint8Array(await photoBlob.arrayBuffer());

  // 6) Resize photo
  let resizedPhoto: Uint8Array;
  try {
    resizedPhoto = await resizePhotoToBox(photoBytes);
  } catch (e) {
    return jsonResponse({ ok: false, error: `photo resize failed: ${e instanceof Error ? e.message : String(e)}` }, 500);
  }

  // 7) Substitute template
  const substitutedHtml = substituteTemplate(tpl.template_html, member as TeamMember);

  // 8) Build ZIP
  const fullName = `${member.first_name} ${member.last_name}`.trim();
  let zipBytes: Uint8Array;
  try {
    zipBytes = await buildSignatureZip({ fullName, substitutedHtml, photoJpeg: resizedPhoto });
  } catch (e) {
    return jsonResponse({ ok: false, error: `zip build failed: ${e instanceof Error ? e.message : String(e)}` }, 500);
  }

  const zipB64 = bytesToBase64(zipBytes);
  const zipFileName = `State Farm Signature - ${fullName}.zip`;

  if (dryRun) {
    return jsonResponse({
      ok: true, status: "dry_run",
      full_name: fullName,
      recipient: member.email_sf,
      cc: PETER_CC,
      zip_size: zipBytes.length,
      photo_size: resizedPhoto.length,
      substituted_html_bytes: substitutedHtml.length,
      substituted_html_preview: substitutedHtml.slice(0, 400),
    });
  }

  // 9) Send email via Composio Gmail
  const firstName = member.first_name!;
  const emailBody = buildEmailBody(firstName);
  const subject = `Your State Farm Email Signature — ${fullName}`;

  const sendRes = await callComposio({
    apiKey: composioApiKey,
    userId: composioUserId,
    connectedAccountId: gmailAccountId,
    toolSlug: "GMAIL_SEND_EMAIL",
    toolArguments: {
      recipient_email: member.email_sf,
      cc: [PETER_CC],
      subject,
      body: emailBody,
      is_html: false,
      attachments: [
        { filename: zipFileName, mimetype: "application/zip", content: zipB64 },
      ],
      user_id: "me",
    },
  });

  const nowIso = new Date().toISOString();

  if (!sendRes.ok) {
    // Log failure
    await sb.from("email_signature_sends").insert({
      agency_id: agencyId,
      team_member_id: teamMemberId,
      recipient_email: member.email_sf,
      triggered_by: triggeredBy,
      status: "failed",
      error_message: String(sendRes.error).slice(0, 1000),
      zip_size_bytes: zipBytes.length,
    });
    return jsonResponse({ ok: false, status: "send_failed", error: sendRes.error }, 502);
  }

  const messageId = (sendRes.data as any)?.id
                  ?? (sendRes.data as any)?.message_id
                  ?? (sendRes.data as any)?.response_data?.id
                  ?? null;

  // 10) Log success
  const { data: sendRow } = await sb.from("email_signature_sends").insert({
    agency_id: agencyId,
    team_member_id: teamMemberId,
    recipient_email: member.email_sf,
    triggered_by: triggeredBy,
    status: "sent",
    gmail_message_id: messageId,
    zip_size_bytes: zipBytes.length,
    sent_at: nowIso,
  }).select("id").single();

  return jsonResponse({
    ok: true, status: "sent",
    recipient: member.email_sf,
    cc: PETER_CC,
    subject,
    message_id: messageId,
    zip_size: zipBytes.length,
    log_id: sendRow?.id ?? null,
  });
}

Deno.serve(run);
