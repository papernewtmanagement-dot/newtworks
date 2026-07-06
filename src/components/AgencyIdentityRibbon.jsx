import { useState, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";

// ============================================================
// AGENCY IDENTITY RIBBON
// Persistent band directly under the app header, on every route.
// Collapsed: four value labels + one-word essence per value.
// Expanded: four-column grid of full statements + office block.
//
// Data:
//   core_principles domain=agency_identity  ->  4 rule bodies + essences
//   agency row                              ->  office details + codes
//
// Rule format expected in core_principles.content:
//   <rule id="vision">**VISION - Trusted**\nBody...</rule>
//   The word between the em-dash and the closing ** is the essence.
//
// State persistence: localStorage key "bcc.identityRibbon.expanded"
// ============================================================

// Fallback content used when the DB read is delayed or fails.
// Keep in sync with core_principles.agency_identity.
const FALLBACK = {
  VISION:  { essence: "Trusted",    body: "We are the trusted resource for anyone who wants to protect and grow their assets and wealth." },
  MISSION: { essence: "Understand", body: "We understand people, and we help them understand what they have, what they don’t have, and why it’s important." },
  CULTURE: { essence: "Dignity",    body: "We like people. We’re positive, diligent, and patient problem-solvers. We tell each other the truth with respect, communicate clearly, and treat every person — customer, teammate, neighbor — with dignity." },
  DUTY:    { essence: "Deliver",    body: "We do what we say we will do. We trust our processes, hit our deadlines, and pursue our goals with focused energy — finding new customers, earning their business honestly, and keeping their trust for the long haul." },
};

const LS_KEY = "bcc.identityRibbon.expanded";
const ORDER = ["VISION", "MISSION", "CULTURE", "DUTY"];

// Parse each <rule id="..."> from the agency_identity principle.
// Expected header line: **LABEL - Essence** (em-dash or hyphen accepted).
// Everything after that line is the body.
function parseIdentity(rawContent) {
  const out = {};
  if (!rawContent) return out;
  const ids = ["vision", "mission", "culture", "duty"];
  for (const id of ids) {
    const re = new RegExp(`<rule id="${id}">([\\s\\S]*?)</rule>`, "i");
    const m = rawContent.match(re);
    if (!m) continue;
    const inner = (m[1] || "").trim();
    const parts = inner.match(/^\*\*([A-Z]+)\s*[—\-]\s*([^*]+?)\*\*\s*([\s\S]+)$/);
    if (parts) {
      out[parts[1].toUpperCase()] = {
        essence: parts[2].trim(),
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
  const [office, setOffice] = useState({
    name: "", address: "", phone: "", customer_email: "",
    sf_agent_code: "", txdi: "", npn: "", jackson_id: "",
  });

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
          .select("name, owner_name, address, phone, customer_email, state_farm_agent_code, txdi_number, national_producer_number, jackson_id")
          .eq("id", AGENCY_ID)
          .maybeSingle();
        if (active && ag) {
          // The agency.name field holds the parent LLC name. For the ribbon,
          // present the agency identity as "<Owner> State Farm".
          const displayName = ag.owner_name ? `${ag.owner_name} State Farm` : (ag.name || "");
          setOffice({
            name: displayName,
            address: ag.address || "",
            phone: ag.phone || "",
            customer_email: ag.customer_email || "",
            sf_agent_code: ag.state_farm_agent_code || "",
            txdi: ag.txdi_number || "",
            npn: ag.national_producer_number || "",
            jackson_id: ag.jackson_id || "",
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
      minWidth: vp.isPhone ? 110 : 0,
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
      fontSize: vp.isPhone ? 14 : 16,
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
    panel: { padding: vp.isPhone ? "10px 12px 16px 12px" : "10px 24px 20px 24px" },
    grid: {
      display: "grid",
      gridTemplateColumns: vp.isPhone ? "1fr" : "repeat(4, 1fr)",
      rowGap: vp.isPhone ? 18 : 0,
      columnGap: vp.isPhone ? 0 : 24,
    },
    card: (idx) => ({
      padding: vp.isPhone ? "8px 0" : "4px 24px 4px 0",
      borderRight: (vp.isPhone || idx === 3) ? "none" : `1px solid ${T.slate200}`,
      borderBottom: vp.isPhone && idx < 3 ? `1px solid ${T.slate200}` : "none",
      paddingBottom: vp.isPhone && idx < 3 ? 16 : (vp.isPhone ? 8 : 4),
    }),
    cardLabel: {
      fontSize: 11,
      fontWeight: 700,
      textTransform: "uppercase",
      letterSpacing: "0.16em",
      color: T.blue,
      marginBottom: 8,
    },
    cardBody: {
      fontSize: vp.isPhone ? 13 : 14,
      lineHeight: 1.55,
      color: T.slate900,
      letterSpacing: "-0.005em",
    },
    office: {
      marginTop: 20,
      paddingTop: 14,
      borderTop: `1px solid ${T.slate200}`,
      display: "flex",
      flexDirection: "column",
      gap: 6,
      fontSize: 11,
      color: T.slate500,
    },
    officeRow: {
      display: "flex",
      flexWrap: "wrap",
      alignItems: "center",
      gap: "0",
    },
    officeName: {
      fontWeight: 600,
      color: T.slate900,
      letterSpacing: "-0.005em",
    },
    officeLabel: {
      textTransform: "uppercase",
      letterSpacing: "0.1em",
      fontSize: 9,
      color: T.slate400,
      fontWeight: 600,
      marginRight: 6,
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

  // Build the office lines (only show what's populated).
  const hasContact = office.phone || office.customer_email;
  const hasCodes   = office.sf_agent_code || office.txdi || office.npn || office.jackson_id;
  const hasAnyOffice = office.name || office.address || hasContact || hasCodes;

  return (
    <div style={css.wrap} aria-label="Agency identity">
      {/* Collapsed row */}
      <div style={css.bar}>
        <div style={css.values}>
          {ORDER.map((k, idx) => (
            <div
              key={k}
              style={css.pill(idx === ORDER.length - 1)}
              onClick={toggle}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); } }}
              aria-label={`${k} — ${identity[k].essence}`}
            >
              <span style={css.pillLabel}>{k}</span>
              <span style={css.pillEssence}>{identity[k].essence}</span>
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
          <div style={css.grid}>
            {ORDER.map((k, idx) => (
              <div key={k} style={css.card(idx)}>
                <div style={css.cardLabel}>{k.charAt(0) + k.slice(1).toLowerCase()}</div>
                <div style={css.cardBody}>{identity[k].body}</div>
              </div>
            ))}
          </div>

          {hasAnyOffice && (
            <div style={css.office}>
              {(office.name || office.address) && (
                <div style={css.officeRow}>
                  {office.name && <span style={css.officeName}>{office.name}</span>}
                  {office.name && office.address && <span style={css.dot}>·</span>}
                  <span>{office.address}</span>
                </div>
              )}
              {hasContact && (
                <div style={css.officeRow}>
                  {office.phone && <><span style={css.officeLabel}>Phone</span><span>{office.phone}</span></>}
                  {office.phone && office.customer_email && <span style={css.dot}>·</span>}
                  {office.customer_email && <><span style={css.officeLabel}>Customer Email</span><span>{office.customer_email}</span></>}
                </div>
              )}
              {hasCodes && (
                <div style={css.officeRow}>
                  {office.sf_agent_code && <><span style={css.officeLabel}>SF Agent</span><span>{office.sf_agent_code}</span></>}
                  {office.sf_agent_code && office.txdi && <span style={css.dot}>·</span>}
                  {office.txdi && <><span style={css.officeLabel}>TXDI</span><span>{office.txdi}</span></>}
                  {(office.sf_agent_code || office.txdi) && office.npn && <span style={css.dot}>·</span>}
                  {office.npn && <><span style={css.officeLabel}>NPN</span><span>{office.npn}</span></>}
                  {(office.sf_agent_code || office.txdi || office.npn) && office.jackson_id && <span style={css.dot}>·</span>}
                  {office.jackson_id && <><span style={css.officeLabel}>Jackson ID</span><span>{office.jackson_id}</span></>}
                </div>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
