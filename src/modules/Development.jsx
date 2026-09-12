// =========================================================================
// Development.jsx
// =========================================================================
// Parent module for everything that grows a teammate: their onboarding plan,
// the trivia/training games, and their licenses and continuing education.
//
// Three tabs, one URL param ("area"). Each tab renders the module that used
// to be its own sidebar entry. Those modules keep their own inner tabs and
// their own URL params — Onboarding uses "subtab", Trivia uses "tab".
// =========================================================================

import { T } from "../lib/theme.js";
import { TabLink, useTabParam } from "../lib/routing.jsx";
import Onboarding from "./Onboarding.jsx";
import Trivia from "./Trivia.jsx";
import Licensing from "./Licensing.jsx";

const AREAS = [
  { id: "onboarding", label: "Onboarding" },
  { id: "trivia",     label: "Trivia" },
  { id: "licensing",  label: "Licensing" },
];

export default function Development({ userRole, userId, embedded = false }) {
  const [area, setArea, areaHref] = useTabParam(
    "area", "onboarding", ["onboarding", "trivia", "licensing"]
  );

  return (
    <div>
      <div style={{ padding: embedded ? 0 : "20px 20px 0" }}>
        {!embedded && (
        <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900, letterSpacing: "-0.02em" }}>
          Development
        </div>
        )}
        <div style={{
          display: "flex", gap: 4, flexWrap: "wrap", marginTop: embedded ? 0 : 12,
          borderBottom: `1px solid ${T.slate200}`,
        }}>
          {AREAS.map(a => {
            const on = a.id === area;
            return (
              <TabLink
                key={a.id}
                href={areaHref(a.id)}
                onSelect={() => setArea(a.id)}
                style={{
                  padding: "8px 14px", fontSize: 13, fontWeight: 600,
                  color: on ? T.blue : T.slate600,
                  background: "transparent",
                  borderBottom: `2px solid ${on ? T.blue : "transparent"}`,
                  marginBottom: -1, textDecoration: "none",
                }}
              >{a.label}</TabLink>
            );
          })}
        </div>
      </div>

      {area === "onboarding" && <Onboarding userRole={userRole} userId={userId} embedded />}
      {area === "trivia"     && <Trivia userRole={userRole} userId={userId} embedded />}
      {area === "licensing"  && <Licensing userRole={userRole} userId={userId} embedded />}
    </div>
  );
}
