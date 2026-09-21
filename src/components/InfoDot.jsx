import { T } from "../lib/theme.js";

// ─── Info button ──────────────────────────────────────────────
// The small round "i" that opens more detail under a line. One button for the
// whole app: checklist rows and commit choices both use it (Peter 2026-09-21).
export default function InfoDot({ open, onClick, title = "More detail" }) {
  return (
    <button type="button" title={title} aria-label={title} aria-expanded={!!open}
      onClick={onClick}
      style={{ flexShrink: 0, width: 18, height: 18, lineHeight: "16px", textAlign: "center", padding: 0, borderRadius: 999, cursor: "pointer", fontFamily: "inherit", fontSize: 11, fontWeight: 700, boxSizing: "border-box", border: `1px solid ${open ? T.blue : T.slate300}`, background: open ? T.blueLt : T.white, color: open ? T.blue : T.slate500 }}>i</button>
  );
}
