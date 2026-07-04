import { useState, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";

// ============================================================
// AGENCY IDENTITY RIBBON
// Persistent band directly under the app header, on every route.
// Collapsed: four value labels + one-phrase essence per value.
// Expanded: full 2x2 (External/Internal x Aspirational/Operational)
//           + office block footer.
//
// Data:
//   core_principles domain=agency_identity  ->  four rule bodies
//   agency row                                ->  office details
//
// State persistence:  localStorage key "bcc.identityRibbon.expanded"
// ============================================================

// Approved essences for the collapsed ribbon (Peter, 2026-07-03).
// One phrase per value, pulled from inside each statements own text.
const ESSENCES = {
  VISION:  "Trusted resource",
  MISSION: "Understand people",
  CULTURE: "Truth with dignity",
  DUTY:    "Do what we say",
};

// Static fallback so the ribbon still renders canonical text if the
// core_principles read is delayed or fails. Kept in sync manually.
const FALLBACK = {
  VISION:  { subhead: "Who we are to our customers", body: "We are the trusted resource for anyone who wants to protect and grow their assets and wealth." },
  MISSION: { subhead: "What we do for them",         body: "We understand people, and we help them understand what they have, what they don’t have, and why it’s important." },
  CULTURE: { subhead: "Who we are with each other",  body: "We like people. We’re positive, diligent, and patient problem-solvers. We tell each other the truth with respect, communicate clearly, and treat every person — customer, teammate, neighbor — with dignity." },
  DUTY:    { subhead: "How we execute",              body: "We do what we say we will do. We trust our processes, hit our deadlines, and pursue our goals with focused energy — finding new customers, earning their business honestly, and keeping their trust for the long haul." },
};

const LS_KEY = "bcc.identityRibbon.expanded";

// Parse each <rule id="..."> block from the agency_identity content.
// Expected format: **LABEL — subhead.**  then body on next line(s).
function parseIdentity(rawContent) {
  const out = {};
  if (!rawContent) return out;
  const ids = ["vision", "mission", "culture", "duty"];
  for (const id of ids) {
    const re = new RegExp(`<rule id="${id}">([\s\S]*?)</rule>`, "i");
    const m = rawContent.match(re);
    if (!m) continue;
    const inner = (m[1] || "").trim();
    const parts = inner.match(/^\*\*([A-Z]+)\s*[—\-]\s*([^*]+?)\*\*\s*([\s\S]+)$/);
    if (parts) {
      out[parts[1].toUpperCase()] = {
        subhead: parts[2].replace(/\.$/, "").trim(),
        body: parts[3].trim(),
      };
    }
  }
  return out;
}

export default function AgencyIdentityRibbon() {
  const vp = useViewport();
  const [expanded, setExpanded] = useState(() => {
    try { return localStorage.getItem(LS_KEY) === "1"; } catch { return false; }
  });
  const [identity, setIdentity] = useState(FALLBACK);
  const [office, setOffice]     = useState({ name: "", address: "", agent_code: "", email: "" });

  useEffect(() => {
    let active = true;
    (async () => {
      try {
        const { data: cp } = await supabase
          .from("core_principles")
          .select("content")
          .eq("agency_id", AGENCY_ID)
          .eq("domain", "agency_identity")
          .eq("is_active", true)
          .maybeSingle();
        if (active && cp?.content) {
          const parsed = parseIdentity(cp.content);
          setIdentity({
            VISION:  parsed.VISION  || FALLBACK.VISION,
            MISSION: parsed.MISSION || FALLBACK.MISSION,
            CULTURE: parsed.CULTURE || FALLBACK.CULTURE,
            DUTY:    parsed.DUTY    || FALLBACK.DUTY,
          });
        }
      } catch (_) { /* keep fallback */ }

      try {
        const { data: ag } = await supabase
          .from("agency")
          .select("name, address, state_farm_agent_code, primary_email")
          .eq("id", AGENCY_ID)
          .maybeSingle();
        if (active && ag) {
          setOffice({
            name: ag.name || "",
            address: ag.address || "",
            agent_code: ag.state_farm_agent_code || "",
            email: ag.primary_email || "",
          });
        }
      } catch (_) { /* office block will just hide */ }
    })();
    return () => { active = false; };
  }, []);

  const toggle = () => {
    setExpanded(v => {
      const nv = !v;
      try { localStorage.setItem(LS_KEY, nv ? "1" : "0"); } catch (_) {}
      return nv;
    });
  };

  const order = ["VISION", "MISSION", "CULTURE", "DUTY"];

  const css = {
    wrap: {
      background: expanded ? T.slate100 : T.white,
      borderBottom: `1px solid ${T.slate200}`,
      transition: "background-color 0.2s ease",
    },
    bar: {
      display: "flex",
      alignItems: "center",
      padding: vp.isPhone ? "0 8px" : "0 20px",
      height: vp.isPhone ? 52 : 60,
      gap: 8,
    },
    values: {
      display: "flex",
      alignItems: "stretch",
      flex: 1,
      justifyContent: "space-between",
      overflowX: vp.isPhone ? "auto" : "visible",
      WebkitOverflowScrolling: "touch",
    },
    pill: (isLast) => ({
      display: "flex",
      flexDirection: "column",
      justifyContent: "center",
      gap: 3,
      padding: vp.isPhone ? "0 12px" : "0 24px",
      flex: vp.isPhone ? "0 0 auto" : 1,
      borderRight: isLast ? "none" : `1px solid ${T.slate200}`,
      cursor: "pointer",
      textAlign: "left",
      transition: "background-color 0.15s ease",
      minWidth: vp.isPhone ? 140 : 0,
    }),
    pillLabel: {
      fontSize: 10,
      fontWeight: 700,
      textTransform: "uppercase",
      letterSpacing: "0.16em",
      color: T.blue,
      lineHeight: 1,
    },
    pillEssence: {
      fontSize: vp.isPhone ? 13 : 15,
      fontWeight: 400,
      color: T.slate900,
      letterSpacing: "-0.01em",
      lineHeight: 1.2,
      whiteSpace: "nowrap",
    },
    toggle: {
      background: "none",
      border: `1px solid ${T.slate200}`,
      borderRadius: 6,
      width: 28,
      height: 28,
      display: "grid",
      placeItems: "center",
      cursor: "pointer",
      color: T.slate500,
      flexShrink: 0,
      padding: 0,
    },
    panel: { padding: vp.isPhone ? "6px 12px 16px 12px" : "6px 24px 20px 24px" },
    quadHeader: {
      display: "grid",
      gridTemplateColumns: "100px 1fr 1fr",
      gap: 24,
      padding: "8px 0 12px 0",
      borderBottom: `1px solid ${T.slate200}`,
      marginBottom: 16,
    },
    quadHeaderLabel: {
      fontSize: 10,
      fontWeight: 600,
      textTransform: "uppercase",
      letterSpacing: "0.14em",
      color: T.slate400,
      textAlign: "center",
    },
    grid: {
      display: "grid",
      gridTemplateColumns: vp.isPhone ? "1fr" : "100px 1fr 1fr",
      rowGap: 20,
      columnGap: vp.isPhone ? 0 : 24,
    },
    rowLabel: {
      fontSize: 10,
      fontWeight: 600,
      textTransform: "uppercase",
      letterSpacing: "0.14em",
      color: T.slate400,
      alignSelf: "center",
      textAlign: vp.isPhone ? "left" : "right",
      paddingRight: vp.isPhone ? 0 : 8,
      borderRight: vp.isPhone ? "none" : `1px solid ${T.slate200}`,
      borderBottom: vp.isPhone ? `1px solid ${T.slate200}` : "none",
      paddingBottom: vp.isPhone ? 6 : 0,
    },
    card: { padding: "4px 0" },
    cardLabel: {
      fontSize: 10,
      fontWeight: 700,
      textTransform: "uppercase",
      letterSpacing: "0.14em",
      color: T.blue,
      marginBottom: 4,
    },
    cardSubhead: {
      fontSize: 11,
      color: T.slate400,
      marginBottom: 8,
      fontStyle: "italic",
    },
    cardBody: {
      fontSize: 14,
      lineHeight: 1.55,
      color: T.slate900,
      letterSpacing: "-0.005em",
    },
    office: {
      marginTop: 20,
      paddingTop: 14,
      borderTop: `1px solid ${T.slate200}`,
      display: "flex",
      justifyContent: "space-between",
      alignItems: "center",
      gap: 16,
      flexWrap: "wrap",
      fontSize: 11,
      color: T.slate500,
    },
    officeName: {
      fontWeight: 600,
      color: T.slate900,
      letterSpacing: "-0.005em",
    },
    dot: { color: T.slate300, margin: "0 8px" },
  };

  const chevron = (
    <svg
      width="12" height="12" viewBox="0 0 12 12" fill="none"
      style={{ transform: expanded ? "rotate(180deg)" : "none", transition: "transform 0.2s ease" }}
    >
      <path d="M2.5 4L6 7.5L9.5 4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );

  return (
    <div style={css.wrap} aria-label="Agency identity">
      {/* Collapsed row */}
      <div style={css.bar}>
        <div style={css.values}>
          {order.map((k, idx) => (
            <div
              key={k}
              style={css.pill(idx === order.length - 1)}
              onClick={toggle}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); } }}
              aria-label={`${k} — ${ESSENCES[k]}`}
            >
              <span style={css.pillLabel}>{k}</span>
              <span style={css.pillEssence}>{ESSENCES[k]}</span>
            </div>
          ))}
        </div>
        <button
          type="button"
          style={css.toggle}
          onClick={toggle}
          aria-label={expanded ? "Collapse identity" : "Expand identity"}
          aria-expanded={expanded}
        >
          {chevron}
        </button>
      </div>

      {/* Expanded panel */}
      {expanded && (
        <div style={css.panel}>
          {!vp.isPhone && (
            <div style={css.quadHeader}>
              <div />
              <div style={css.quadHeaderLabel}>External · About Customers</div>
              <div style={css.quadHeaderLabel}>Internal · About Us</div>
            </div>
          )}

          <div style={css.grid}>
            <div style={css.rowLabel}>Aspirational</div>
            <div style={css.card}>
              <div style={css.cardLabel}>Vision</div>
              <div style={css.cardSubhead}>{identity.VISION.subhead}</div>
              <div style={css.cardBody}>{identity.VISION.body}</div>
            </div>
            <div style={css.card}>
              <div style={css.cardLabel}>Culture</div>
              <div style={css.cardSubhead}>{identity.CULTURE.subhead}</div>
              <div style={css.cardBody}>{identity.CULTURE.body}</div>
            </div>

            <div style={css.rowLabel}>Operational</div>
            <div style={css.card}>
              <div style={css.cardLabel}>Mission</div>
              <div style={css.cardSubhead}>{identity.MISSION.subhead}</div>
              <div style={css.cardBody}>{identity.MISSION.body}</div>
            </div>
            <div style={css.card}>
              <div style={css.cardLabel}>Duty</div>
              <div style={css.cardSubhead}>{identity.DUTY.subhead}</div>
              <div style={css.cardBody}>{identity.DUTY.body}</div>
            </div>
          </div>

          {(office.name || office.address || office.agent_code || office.email) && (
            <div style={css.office}>
              <div>
                {office.name && <span style={css.officeName}>{office.name}</span>}
                {office.name && office.address && <span style={css.dot}>·</span>}
                {office.address}
              </div>
              <div>
                {office.agent_code && <>SF Agent {office.agent_code}</>}
                {office.agent_code && office.email && <span style={css.dot}>·</span>}
                {office.email}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
