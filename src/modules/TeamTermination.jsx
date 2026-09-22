import { useCallback, useEffect, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { mdToHtml } from "../lib/markdown.js";
import { ManualBodyStyles } from "../lib/manualBodyStyles.jsx";

// =========================================================================
// TeamTermination.jsx: the Team → Termination tab
// =========================================================================
// Holds the termination checklist (public.termination_checklist, one row per
// agency). The terminate button on a team member runs the edge function
// terminate-team-member, which reads this row, fills in the person's name,
// alias and extension, and emails the checklist to Peter.
// Moved here from the Admin manual's Termination page 2026-09-22.
// =========================================================================

export default function TeamTermination() {
  const vp = useViewport();
  const [content, setContent] = useState("");
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setError("");
    const { data, error: err } = await supabase
      .from("termination_checklist")
      .select("content_md")
      .eq("agency_id", AGENCY_ID)
      .maybeSingle();
    if (err) setError(err.message);
    setContent(data?.content_md || "");
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const save = async () => {
    setSaving(true);
    setError("");
    const { error: err } = await supabase
      .from("termination_checklist")
      .upsert(
        { agency_id: AGENCY_ID, content_md: draft, updated_at: new Date().toISOString() },
        { onConflict: "agency_id" }
      );
    setSaving(false);
    if (err) { setError(err.message); return; }
    setEditing(false);
    await load();
  };

  const card = {
    background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12,
    padding: vp.isPhone ? 14 : 20, boxSizing: "border-box",
  };
  const btn = {
    padding: "7px 14px", borderRadius: 8, border: `1px solid ${T.slate300}`,
    background: T.white, color: T.slate700, fontSize: 13, fontWeight: 600,
    cursor: "pointer", boxSizing: "border-box",
  };
  const btnMain = { ...btn, background: T.blue, borderColor: T.blue, color: T.white };

  return (
    <div style={card}>
      <ManualBodyStyles />
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 10, flexWrap: "wrap", marginBottom: 12 }}>
        <div>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>Termination checklist</div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 3 }}>
            Emailed to you, filled in with their name, alias and extension, whenever you terminate someone.
          </div>
        </div>
        {!editing && !loading && (
          <button type="button" style={btn} onClick={() => { setDraft(content); setEditing(true); }}>Edit</button>
        )}
      </div>

      {error && (
        <div style={{ background: T.redLt, color: T.red, fontSize: 12, padding: "8px 10px", borderRadius: 8, marginBottom: 10 }}>{error}</div>
      )}

      {loading ? (
        <div style={{ fontSize: 13, color: T.slate500 }}>Loading…</div>
      ) : editing ? (
        <div>
          <textarea
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            rows={16}
            style={{ width: "100%", boxSizing: "border-box", fontSize: 13, lineHeight: 1.5, padding: 10, border: `1px solid ${T.slate300}`, borderRadius: 8, fontFamily: "ui-monospace, monospace", resize: "vertical" }}
          />
          <div style={{ display: "flex", gap: 8, marginTop: 10, flexWrap: "wrap" }}>
            <button type="button" style={btnMain} onClick={save} disabled={saving}>{saving ? "Saving…" : "Save"}</button>
            <button type="button" style={btn} onClick={() => setEditing(false)} disabled={saving}>Cancel</button>
          </div>
        </div>
      ) : content.trim() ? (
        <div className="newtworks-handbook-body" dangerouslySetInnerHTML={{ __html: mdToHtml(content) }} />
      ) : (
        <div style={{ fontSize: 13, color: T.slate500 }}>No checklist saved yet. Tap Edit to add one.</div>
      )}
    </div>
  );
}
