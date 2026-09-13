import { useState, useEffect, useCallback, useMemo } from "react";
import { T } from "../lib/theme.js";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";

// Every email the hiring process sends a candidate, in one place, editable.
// The wording used to live inside two database functions and the interview
// scheduler, so changing a letter meant changing code. These rows are what
// actually gets sent now — the senders read this table at send time.
//
// {{tokens}} are filled in by the sender. Preview swaps in sample values so
// the letter can be read the way a candidate would see it.

const SAMPLE = {
  first_name: "Sam",
  position: "Account Manager",
  role_phrase: "the <strong>Account Manager</strong> role",
  assessment_link: "https://newtworks.vercel.app/assessment/sample-link",
  booking_url: "https://newtworks.vercel.app/interview/sample-link",
  when: "Tuesday, October 7 at 1:00 PM",
  old_when: "Monday, October 6 at 10:00 AM",
  reason: "A scheduling conflict came up",
  meet_url: "https://meet.google.com/abc-defg-hij",
  meet_line: '<p>Google Meet link: <a href="https://meet.google.com/abc-defg-hij">https://meet.google.com/abc-defg-hij</a></p>',
  response_buttons:
    '<p><a href="#" style="display:inline-block;margin:6px 8px 6px 0;padding:10px 16px;border-radius:8px;background:#2563eb;color:#fff;text-decoration:none;font-weight:600;">Yes, I\'ll be there</a>' +
    '<a href="#" style="display:inline-block;margin:6px 8px 6px 0;padding:10px 16px;border-radius:8px;background:#475569;color:#fff;text-decoration:none;font-weight:600;">I need a different time</a></p>' +
    '<p style="font-size:13px;color:#64748b;">No longer interested? <a href="#">Let us know here</a> and we\'ll open the time up for someone else.</p>',
  options_list: "<li>Monday, October 6 at 10:00 AM</li><li>Tuesday, October 7 at 10:00 AM</li>",
  where_block: '<p>We\'ll meet at our office:<br/>1234 Example Ave, San Antonio, TX</p>',
  note_block: "<p>Parking is free in the front lot.</p>",
};

function fillTokens(text, extra) {
  let out = String(text || "");
  const vars = { ...SAMPLE, ...(extra || {}) };
  for (const key of Object.keys(vars)) {
    out = out.split(`{{${key}}}`).join(vars[key]);
  }
  return out;
}

// Tokens written into the body that nobody filled in — usually a typo.
function unknownTokens(row) {
  const found = new Set();
  const re = /\{\{([a-z0-9_]+)\}\}/gi;
  let m;
  const haystack = `${row.subject || ""} ${row.body_html || ""}`;
  while ((m = re.exec(haystack)) !== null) {
    if (!Object.prototype.hasOwnProperty.call(SAMPLE, m[1])) found.add(m[1]);
  }
  return [...found];
}

export default function HiringEmailTemplates() {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(false);
  const [openKey, setOpenKey, keyHref] = useTabParam("tpl", null);
  const [draft, setDraft] = useState(null); // { subject, body_html }
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState("");
  const [savedAt, setSavedAt] = useState(null);
  const [showPreview, setShowPreview] = useState(true);

  // The offer letter lives in its own table because the offer form fills it
  // in and files the finished copy on the candidate. It is still a letter a
  // candidate reads, so it belongs on this list — mapped into the same shape,
  // written back to its own table.
  const load = useCallback(async () => {
    if (!supabase || !AGENCY_ID) return;
    setLoading(true);
    const [tpl, offer] = await Promise.all([
      supabase
        .from("hiring_email_templates")
        .select("id, template_key, title, stage, sort_order, subject, body_html, tokens, description, sent_when, updated_at")
        .eq("agency_id", AGENCY_ID)
        .order("sort_order", { ascending: true }),
      supabase
        .from("offer_letter_templates")
        .select("id, template_key, title, body_md, is_active, updated_at")
        .eq("agency_id", AGENCY_ID)
        .eq("is_active", true),
    ]);
    setLoadError(!!tpl.error);
    const offerRows = (offer.error ? [] : (offer.data || [])).map((r) => ({
      id: r.id,
      source: "offer",
      template_key: `offer_${r.template_key}`,
      title: r.title || "Offer letter",
      stage: "Offer",
      sort_order: 135,
      subject: "",
      body_html: r.body_md || "",
      tokens: [],
      description: "The offer letter itself. The offer form fills in the name, pay and dates, then files the finished copy on the candidate.",
      sent_when: "Manually, from the offer form on the candidate record.",
      updated_at: r.updated_at,
    }));
    const all = [...(tpl.error ? [] : (tpl.data || [])).map((r) => ({ ...r, source: "hiring" })), ...offerRows];
    all.sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));
    setRows(all);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const current = useMemo(
    () => (rows || []).find((r) => r.template_key === openKey) || null,
    [rows, openKey]
  );

  // A fresh selection starts from whatever is saved.
  useEffect(() => {
    if (!current) { setDraft(null); return; }
    setDraft({ subject: current.subject || "", body_html: current.body_html || "" });
    setSaveError("");
    setSavedAt(null);
  }, [current?.id]);

  const prepRow = (rows || []).find((r) => r.template_key === "snippet_prep_line");
  const previewExtra = { prep_line: prepRow?.body_html || "" };

  const dirty = !!(draft && current && (draft.subject !== (current.subject || "") || draft.body_html !== (current.body_html || "")));

  const save = async () => {
    if (!current || !draft) return;
    setSaving(true);
    setSaveError("");
    const { error } = current.source === "offer"
      ? await supabase
          .from("offer_letter_templates")
          .update({ body_md: draft.body_html })
          .eq("id", current.id)
      : await supabase
          .from("hiring_email_templates")
          .update({ subject: draft.subject, body_html: draft.body_html })
          .eq("id", current.id);
    setSaving(false);
    if (error) { setSaveError(error.message || "Save failed."); return; }
    setSavedAt(new Date());
    await load();
  };

  if (loading) {
    return <div style={{ fontSize: 12, color: T.slate400, textAlign: "center", padding: "28px 16px" }}>Loading templates…</div>;
  }

  if (loadError) {
    return (
      <div style={{ background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: "28px 16px", textAlign: "center" }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: T.slate700, marginBottom: 4 }}>Couldn't load the email templates</div>
        <button onClick={load} style={{ marginTop: 10, padding: "7px 16px", fontSize: 12, fontWeight: 600, color: T.white, background: T.blue, border: "none", borderRadius: 7, cursor: "pointer" }}>
          Retry
        </button>
      </div>
    );
  }

  // ── Editor view ────────────────────────────────────────────────────────
  if (current && draft) {
    const isSnippet = current.template_key === "snippet_prep_line";
    const isOffer = current.source === "offer";
    const missing = isOffer ? [] : unknownTokens(draft);
    return (
      <div style={{ padding: _pad, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, boxSizing: "border-box" }}>
        <TabLink
          href={keyHref(null)}
          onSelect={() => setOpenKey(null)}
          style={{ fontSize: 12, color: T.blue, textDecoration: "none", fontWeight: 600 }}
        >
          ← All templates
        </TabLink>

        <div style={{ marginTop: 12, marginBottom: 14 }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>{current.title}</div>
          {current.description && (
            <div style={{ fontSize: 12, color: T.slate600, marginTop: 4 }}>{current.description}</div>
          )}
          {current.sent_when && (
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 4 }}>Sends: {current.sent_when}</div>
          )}
        </div>

        {!isSnippet && !isOffer && (
          <label style={{ display: "block", marginBottom: 12 }}>
            <span style={{ display: "block", fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 5 }}>Subject line</span>
            <input
              value={draft.subject}
              onChange={(e) => setDraft({ ...draft, subject: e.target.value })}
              style={{ width: "100%", boxSizing: "border-box", padding: "9px 11px", fontSize: 13, color: T.slate900, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 7 }}
            />
          </label>
        )}

        <label style={{ display: "block" }}>
          <span style={{ display: "block", fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 5 }}>
            {isSnippet ? "Wording" : isOffer ? "Letter" : "Body"}
          </span>
          <textarea
            value={draft.body_html}
            onChange={(e) => setDraft({ ...draft, body_html: e.target.value })}
            rows={isSnippet ? 4 : _vp.isPhone ? 14 : 20}
            spellCheck
            style={{ width: "100%", boxSizing: "border-box", padding: "10px 11px", fontSize: 12, lineHeight: 1.55, fontFamily: "ui-monospace, Menlo, Consolas, monospace", color: T.slate900, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 7, resize: "vertical" }}
          />
        </label>

        {Array.isArray(current.tokens) && current.tokens.length > 0 && (
          <div style={{ marginTop: 10 }}>
            <div style={{ fontSize: 11, fontWeight: 600, color: T.slate600, marginBottom: 5 }}>
              Fill-ins you can use — type them exactly, including the braces
            </div>
            <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
              {current.tokens.map((tok) => (
                <span key={tok} style={{ fontSize: 11, fontFamily: "ui-monospace, Menlo, Consolas, monospace", color: T.slate700, background: T.slate100, border: `1px solid ${T.slate200}`, borderRadius: 5, padding: "3px 7px", boxSizing: "border-box" }}>
                  {`{{${tok}}}`}
                </span>
              ))}
            </div>
          </div>
        )}

        {missing.length > 0 && (
          <div style={{ marginTop: 10, fontSize: 11, color: T.red }}>
            These fill-ins are not recognized and will send as literal text: {missing.map((t) => `{{${t}}}`).join(", ")}
          </div>
        )}

        <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: 8, marginTop: 14 }}>
          <button
            onClick={save}
            disabled={!dirty || saving}
            style={{ padding: "8px 18px", fontSize: 12, fontWeight: 600, color: T.white, background: dirty ? T.blue : T.slate300, border: "none", borderRadius: 7, cursor: dirty && !saving ? "pointer" : "default" }}
          >
            {saving ? "Saving…" : "Save"}
          </button>
          <button
            onClick={() => setDraft({ subject: current.subject || "", body_html: current.body_html || "" })}
            disabled={!dirty || saving}
            style={{ padding: "8px 14px", fontSize: 12, fontWeight: 600, color: T.slate700, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 7, cursor: dirty && !saving ? "pointer" : "default" }}
          >
            Undo changes
          </button>
          {savedAt && !dirty && <span style={{ fontSize: 11, color: T.green, fontWeight: 600 }}>Saved</span>}
          {saveError && <span style={{ fontSize: 11, color: T.red }}>{saveError}</span>}
        </div>

        <div style={{ marginTop: 18, borderTop: `1px solid ${T.slate200}`, paddingTop: 14 }}>
          <button
            onClick={() => setShowPreview(!showPreview)}
            style={{ fontSize: 11, fontWeight: 600, color: T.slate600, background: "transparent", border: "none", padding: 0, cursor: "pointer" }}
          >
            {showPreview ? "Hide preview" : "Show preview"}
          </button>
          {showPreview && (
            <div style={{ marginTop: 10 }}>
              {!isSnippet && !isOffer && (
                <div style={{ fontSize: 12, color: T.slate700, marginBottom: 8 }}>
                  <strong>{fillTokens(draft.subject, previewExtra)}</strong>
                </div>
              )}
              {isOffer ? (
                <div style={{ fontSize: 13, lineHeight: 1.6, color: T.slate800, background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 8, padding: 14, boxSizing: "border-box", whiteSpace: "pre-wrap", overflowX: "auto" }}>
                  {draft.body_html}
                </div>
              ) : (
                <div
                  style={{ fontSize: 13, lineHeight: 1.6, color: T.slate800, background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 8, padding: 14, boxSizing: "border-box", overflowX: "auto" }}
                  dangerouslySetInnerHTML={{ __html: fillTokens(draft.body_html, previewExtra) }}
                />
              )}
              <div style={{ fontSize: 10, color: T.slate400, marginTop: 6 }}>
                {isOffer
                  ? "The fill-ins stay as they are here. The offer form replaces them with the real name, pay and dates."
                  : "Sample name and times. The real letter uses the candidate's own details."}
              </div>
            </div>
          )}
        </div>
      </div>
    );
  }

  // ── List view ──────────────────────────────────────────────────────────
  const stages = [];
  for (const r of rows) {
    let group = stages.find((g) => g.stage === r.stage);
    if (!group) { group = { stage: r.stage, items: [] }; stages.push(group); }
    group.items.push(r);
  }

  return (
    <div>
      <div style={{ fontSize: 12, color: T.slate600, marginBottom: 14 }}>
        Every email a candidate gets, in the order the process sends them. Open one to change the wording — what you save here is what goes out.
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
        {stages.map((g) => (
          <div key={g.stage}>
            <div style={{ fontSize: 11, fontWeight: 700, letterSpacing: 0.4, textTransform: "uppercase", color: T.slate500, marginBottom: 7 }}>
              {g.stage}
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
              {g.items.map((r) => (
                <TabLink
                  key={r.template_key}
                  href={keyHref(r.template_key)}
                  onSelect={() => setOpenKey(r.template_key)}
                  style={{
                    display: "block",
                    padding: _vp.isPhone ? "10px 12px" : "11px 14px",
                    background: T.white,
                    border: `1px solid ${T.slate200}`,
                    borderRadius: 8,
                    textDecoration: "none",
                    boxSizing: "border-box",
                    cursor: "pointer",
                  }}
                >
                  <div style={{ fontSize: 13, fontWeight: 600, color: T.slate900 }}>{r.title}</div>
                  <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
                    {r.subject || r.description || ""}
                  </div>
                </TabLink>
              ))}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
