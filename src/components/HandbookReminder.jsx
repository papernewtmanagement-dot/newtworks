import { useState, useEffect, useCallback } from "react";
import { supabase } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { FormPopupProvider, useOpenForm } from "../lib/onboardingUi.jsx";
import { FORMS_CHANGED } from "./TeamForms.jsx";

// =========================================================================
// HandbookReminder.jsx
// =========================================================================
// A bar across the top of every page while the person signed in still has to
// confirm the current handbook: when they first join, and again every time a
// new version is published. Its button opens the same Handbook form pop-up
// the onboarding plan uses, and the bar goes away once they confirm.
// Peter wrote the handbook, so it never shows for the owner.
// =========================================================================

export default function HandbookReminder({ teamMemberId, role }) {
  const [row, setRow] = useState(null);

  const load = useCallback(async () => {
    if (!supabase || !teamMemberId) { setRow(null); return; }
    const { data } = await supabase
      .from("v_team_form_status")
      .select("state, last_completed_at")
      .eq("team_id", teamMemberId)
      .eq("form_type", "handbook_ack")
      .maybeSingle();
    setRow(data || null);
  }, [teamMemberId]);

  useEffect(() => { load(); }, [load]);

  // Confirming from Development > Forms instead of this bar clears it too.
  useEffect(() => {
    window.addEventListener(FORMS_CHANGED, load);
    return () => window.removeEventListener(FORMS_CHANGED, load);
  }, [load]);

  if (role === "owner" || !teamMemberId || row?.state !== "action_needed") return null;

  return (
    <FormPopupProvider teamId={teamMemberId} onClosed={load}>
      <Bar updated={!!row?.last_completed_at} />
    </FormPopupProvider>
  );
}

function Bar({ updated }) {
  const openForm = useOpenForm();
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap",
      padding: "10px 14px", marginBottom: 14, boxSizing: "border-box",
      background: T.amberLt, border: `1px solid ${T.amber}`, borderRadius: 10,
    }}>
      <div style={{ flex: "1 1 220px", minWidth: 0, fontSize: 13.5, color: T.slate900, lineHeight: 1.45 }}>
        {updated
          ? "The handbook has changed. Please read the new version and confirm."
          : "Please read the handbook and confirm you understand it."}
      </div>
      <button
        onClick={() => openForm && openForm("handbook_ack")}
        style={{
          border: "none", borderRadius: 8, padding: "8px 14px", cursor: "pointer",
          background: T.slate900, color: T.white, fontSize: 13, fontWeight: 600,
          whiteSpace: "nowrap",
        }}
      >Read and confirm</button>
    </div>
  );
}
