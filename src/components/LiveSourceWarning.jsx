import { T } from "../lib/theme.js";

// What the Processes manual no longer has that the Live tab hooks into, from
// the one check in src/lib/liveCall.js (liveSourceProblems). The Live tab and
// every Processes page show it, to whoever can see the Live tab, so an edit to
// the manual can never break a call quietly (Peter 2026-10-04: no drift).
export default function LiveSourceWarning({ problems, where = "live" }) {
  if (!Array.isArray(problems) || !problems.length) return null;
  const inManual = where === "manual";
  return (
    <div className="nw-print-hide" style={{ padding: "12px 16px", borderRadius: 10, border: `1px solid ${T.amber}`, background: T.amberLt, color: T.slate800, fontSize: 13, lineHeight: 1.5 }}>
      <div style={{ fontWeight: 800, marginBottom: 6 }}>
        ⚠️ {inManual ? "The Live tab can't follow these parts of the manual any more:" : "The Processes manual has changed in ways the Live tab can't follow yet:"}
      </div>
      <ul style={{ margin: 0, paddingLeft: 18 }}>
        {problems.map((p, i) => <li key={i}><strong>{p.what}</strong> isn't where the Live tab looks for it. {p.why}</li>)}
      </ul>
      <div style={{ marginTop: 6, color: T.slate600 }}>
        {inManual ? "Put it back, or ask Claude to point the Live tab at its new place." : "Every other step still reads straight from the manual."}
      </div>
    </div>
  );
}
