import { useState, useEffect, useCallback } from "react";
import { T } from "../lib/theme.js";
import { loadOngoing, DEVELOPMENT_CHANGED } from "../lib/development.js";

// =========================================================================
// DevelopmentReminder.jsx
// =========================================================================
// A bar across the top of every page while the person signed in has
// anything on their Ongoing card in Development: a license or CE coming due,
// the handbook to confirm, or their part of a new hire's plan. It goes away
// once the card is clear. What counts is decided once, by
// development_ongoing() in the database.
// =========================================================================

export default function DevelopmentReminder({ teamMemberId }) {
  const [count, setCount] = useState(0);

  const load = useCallback(async () => {
    const items = await loadOngoing(teamMemberId);
    setCount(items.length);
  }, [teamMemberId]);

  useEffect(() => { load(); }, [load]);

  // Something finished on Development clears it without a reload.
  useEffect(() => {
    window.addEventListener(DEVELOPMENT_CHANGED, load);
    window.addEventListener("focus", load);
    return () => {
      window.removeEventListener(DEVELOPMENT_CHANGED, load);
      window.removeEventListener("focus", load);
    };
  }, [load]);

  if (!teamMemberId || count === 0) return null;

  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap",
      padding: "10px 14px", marginBottom: 14, boxSizing: "border-box",
      background: T.amberLt, border: `1px solid ${T.amber}`, borderRadius: 10,
    }}>
      <div style={{ flex: "1 1 220px", minWidth: 0, fontSize: 13.5, color: T.slate900, lineHeight: 1.45 }}>
        You have something due in Development.
      </div>
      <a
        href="/?tab=development"
        style={{
          display: "inline-block", boxSizing: "border-box", borderRadius: 8, padding: "8px 14px",
          background: T.slate900, color: T.white, fontSize: 13, fontWeight: 600,
          whiteSpace: "nowrap", textDecoration: "none",
        }}
      >Open Development</a>
    </div>
  );
}
