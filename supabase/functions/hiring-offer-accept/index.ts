// =========================================================================
// hiring-offer-accept edge function
// =========================================================================
// The public side of the contingent offer. Two jobs, both reached only by
// the one-time link in the offer email:
//
//   mode="get_offer"  (public, token gated)
//     The acceptance page asks who the link belongs to and what the letter
//     said. Returns nothing sensitive — no Social Security number, no
//     scores, no interview notes.
//
//   mode="accept"  (public, token gated)
//     The candidate accepted. Their details and their three reference
//     contacts go in, the link is spent, and the candidate moves to
//     reference check. We confirm to them by email and tell Peter.
//
// All the real work is in three database functions, so the rules about what
// is required and where the Social Security number is filed live in one
// place rather than being restated here. This function is the door, not the
// logic.
// =========================================================================

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { sb, jsonResponse, corsJson, CORS_HEADERS, AGENCY_ID_DEFAULT, getSettingOrNull } from "../_shared/supabase.ts";
import { getComposioGmailCreds, sendGmail } from "../_shared/gmail.ts";
import { escHtml } from "../_shared/html.ts";

async function appBase(agencyId: string): Promise<string> {
  return (await getSettingOrNull(agencyId, "app_base_url")) || "https://newtworks.vercel.app";
}

// -------------------------------------------------------------------------
// What the page may show
// -------------------------------------------------------------------------
async function getOffer(agencyId: string, token: string): Promise<Response> {
  const { data, error } = await sb.rpc("hiring_offer_accept_view", { p_token: token });
  if (error) return corsJson({ ok: false, error: "lookup_failed" }, 500);
  return corsJson(data ?? { ok: false, error: "not_found" });
}

// -------------------------------------------------------------------------
// The candidate accepting
// -------------------------------------------------------------------------
async function accept(agencyId: string, token: string, payload: unknown): Promise<Response> {
  const { data, error } = await sb.rpc("hiring_accept_offer", {
    p_token: token,
    p_payload: payload ?? {},
  });
  if (error) {
    console.error("hiring_accept_offer failed", error);
    return corsJson({ ok: false, error: "save_failed" }, 500);
  }

  const result = data as { ok?: boolean; error?: string; candidate_id?: string } | null;
  if (!result?.ok) return corsJson(result ?? { ok: false, error: "save_failed" }, 400);

  // Everything below is courtesy. If any of it fails the acceptance still
  // stands, so nothing here is allowed to turn a saved acceptance into an
  // error on the candidate's screen.
  try {
    const { data: c } = await sb
      .from("hiring_candidates")
      .select("first_name, candidate_name, email, offer_job_title, offer_start_date, reference_caller_kind, reference_caller_name")
      .eq("id", result.candidate_id)
      .single();

    const { data: refs } = await sb
      .from("hiring_reference_contacts")
      .select("slot_number, contact_name, relationship, phone, email")
      .eq("candidate_id", result.candidate_id)
      .order("slot_number");

    const firstName = c?.first_name || (c?.candidate_name || "").split(" ")[0] || "there";

    if (c?.email) {
      const creds = await getComposioGmailCreds(agencyId);
      if (creds?.creds) {
        const refList = (refs ?? [])
          .map((r) => `<li>${escHtml(r.contact_name)}${r.relationship ? ` — ${escHtml(r.relationship)}` : ""}</li>`)
          .join("");
        await sendGmail({
          creds: creds.creds,
          to: c.email,
          subject: "We have your acceptance — thank you",
          html:
            `<p>Hi ${escHtml(firstName)},</p>` +
            `<p>Thanks — we have your acceptance` +
            (c.offer_job_title ? ` for the ${escHtml(c.offer_job_title)} role` : "") +
            (c.offer_start_date ? `, starting ${escHtml(String(c.offer_start_date))}` : "") +
            `. Your details are in and you do not need to send us anything else for now.</p>` +
            `<p><b>What happens next.</b> We will call the three people you gave us:</p>` +
            `<ul>${refList}</ul>` +
            `<p>Please give them a heads up that we will be ringing, and let us know if any of ` +
            `their numbers change. Once we have spoken to them we will be in touch about your ` +
            `start date and what to bring on the first day.</p>` +
            `<p>If anything you entered was wrong, just reply to this email and we will fix it.</p>`,
        });
      }
    }

    const who =
      c?.reference_caller_kind === "outside"
        ? c?.reference_caller_name || "someone outside the agency"
        : c?.reference_caller_kind === "team"
        ? c?.reference_caller_name || "a teammate"
        : "the retention team";

    const base = await appBase(agencyId);
    await sb.rpc("telegram_send", {
      p_route_key: "admin",
      p_text:
        `<b>${escHtml(c?.candidate_name || firstName)} accepted the offer</b>\n` +
        `Details and ${(refs ?? []).length} reference contacts are in.\n` +
        `Calling is with ${escHtml(who)}.\n\n` +
        `${base}/hiring`,
      p_agency_id: agencyId,
      p_parse_mode: "HTML",
    });
  } catch (e) {
    console.error("post-acceptance notices failed (acceptance itself is saved)", e);
  }

  return corsJson({ ok: true });
}

// -------------------------------------------------------------------------
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });

  let body: any = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }
  const agencyId = body.agency_id || AGENCY_ID_DEFAULT;

  if (body.mode === "get_offer") {
    if (!body.token) return corsJson({ ok: false, error: "missing token" }, 400);
    return await getOffer(agencyId, String(body.token));
  }

  if (body.mode === "accept") {
    if (!body.token) return corsJson({ ok: false, error: "missing token" }, 400);
    return await accept(agencyId, String(body.token), body.payload);
  }

  return jsonResponse({ ok: false, error: "unknown mode" }, 400);
});
