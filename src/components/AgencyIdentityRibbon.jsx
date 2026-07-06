import { useState, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";

// ============================================================
// AGENCY IDENTITY RIBBON
// Persistent band directly under the app header, on every route.
//
// Collapsed:
//   Four value labels + one-word essence per value.
//
// Expanded:
//   - Same pill row, but essence hidden (full statements below make it redundant).
//   - Four-column grid of full value statements (no repeated titles — the
//     pills above serve as the column headers).
//   - Rules of the Road (inline; no longer a handbook page).
//   - When You Get Stuck (mirror of the processes page; ribbon has to be
//     reachable from anywhere in the app).
//   - NATO Phonetic Alphabet (same — always-available reference).
//   - Office block.
//
// Data:
//   core_principles domain=agency_identity  ->  4 rule bodies + essences
//   agency row                              ->  office details + codes
//
//   Rules of the Road, When You Get Stuck, and NATO Alphabet are hard-coded
//   below so the ribbon is self-contained (no extra queries on every mount,
//   and the Rules of the Road content moved out of the handbook table entirely).
//
// State persistence: localStorage key "bcc.identityRibbon.expanded"
// ============================================================

const FALLBACK = {
  VISION:  { essence: "Trusted",    body: "We are the trusted resource for anyone who wants to protect and grow their assets and wealth." },
  MISSION: { essence: "Understand", body: "We understand people, and we help them understand what they have, what they don\u2019t have, and why it\u2019s important." },
  CULTURE: { essence: "Dignity",    body: "We like people. We\u2019re positive, diligent, and patient problem-solvers. We tell each other the truth with respect, communicate clearly, and treat every person \u2014 customer, teammate, neighbor \u2014 with dignity." },
  DUTY:    { essence: "Deliver",    body: "We do what we say we will do. We trust our processes, hit our deadlines, and pursue our goals with focused energy \u2014 finding new customers, earning their business honestly, and keeping their trust for the long haul." },
};

const LS_KEY = "bcc.identityRibbon.expanded";
const ORDER = ["VISION", "MISSION", "CULTURE", "DUTY"];

// ---- Rules of the Road (moved out of the handbook 2026-07-05) ----
const RULES_OF_ROAD = [
  {
    heading: "Customer information",
    items: [
      { emphasis: "NEVER", rest: "contact anyone who isn't a customer or State Farm except to prospect for new business." },
      { emphasis: "ALWAYS", rest: "make sure at least one named insured is in the conversation when discussing ANY of their information." },
      { emphasis: "NEVER", rest: "give information about existing policies to anyone who isn't listed on that policy or part of State Farm." },
      { emphasis: "NEVER", rest: "allow changes to existing policies from anyone who isn't the named insured or authorized by them.", sub: [
        "Commercial policy: the business owner can authorize a representative.",
        "Quote using someone else's information: they have to give consent, unless it's a family member of the person quoting AND part of THEIR insurance household.",
      ] },
    ],
  },
  {
    heading: "Recordkeeping",
    items: [
      { emphasis: "ALWAYS", rest: "keep the Microsoft Notepad on your desktop named \"To-Dos\" open.", sub: [
        "Use it for conversation notes during calls.",
        "Copy those notes into a log/task in ECRM after the call.",
      ] },
      { emphasis: "ALWAYS", rest: "record interactions related to prospects and customers in ECRM." },
    ],
  },
  {
    heading: "How we treat each other and everyone else",
    items: [
      { rest: "Thank each other, customers, and prospects: \u201cThank you for trusting us to look after you.\u201d" },
      { rest: "Always answer each other \u2014 and for each other \u2014 on Teams and video calls." },
    ],
  },
];

// ---- When You Get Stuck (mirrors processes.newtworks-when-stuck) ----
const WHEN_STUCK = [
  {
    heading: "Coverage or policy question",
    items: [
      "Navi search \u2014 do not chat yet.",
      "Answers (Auto, Fire, Life, Modernized).",
      "ABS Sections and Searching.",
      "Ask the office.",
      "Chat with the back office.",
      "Call the back office with permission.",
    ],
  },
  {
    heading: "Tech problem",
    items: [
      "Breathe.",
      "Believe that it's working fine.",
      "Double-check that it's not a user error.",
      "Verify the source of the problem (switch plugs, docks, etc.).",
      "Do a software reset.",
      "Navi search \u2014 do not chat yet.",
      "If a non-internal system, Google it.",
      "Ask the office.",
      "Do a hard reset.",
      "Chat with the back office.",
      "Call the back office with permission.",
    ],
  },
];

// ---- NATO Phonetic Alphabet ----
const NATO = [
  "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel",
  "India", "Juliet", "Kilo", "Lima", "Mike", "November", "Oscar", "Papa",
  "Quebec", "Romeo", "Sierra", "Tango", "Uniform", "Victor", "Whiskey",
  "X-Ray", "Yankee", "Zulu",
];

// Parse each <rule id="..."> from the agency_identity principle.
// Expected header line: **LABEL - Essence** (em-dash or hyphen accepted).
function parseIdentity(rawContent) {
  const out = {};
  if (!rawContent) return out;
  const ids = ["vision", "mission", "culture", "duty"];
  for (const id of ids) {
    const re = new RegExp(`<rule id="${id}">([\\s\\S]*?)</rule>`, "i");
    const m = rawContent.match(re);
    if (!m) continue;
    const inner = (m[1] || "").trim();
    const parts = inner.match(/^\*\*([A-Z]+)\s*[\u2014\-]\s*([^*]+?)\*\*\s*([\s\S]+)$/);
    if (parts) {
      out[parts[1].toUpperCase()] = {
        essence: parts[2].trim(),
        body: parts[3].trim(),
      };
    }
  }
  return out;
}

// ---- Who Handles What (live from public.book_alpha_split) ----
// Fetches on mount inside expanded ribbon only.
// Renders range only (e.g. "A-K"), no nicknames, defensive against any data quirk.
function AlphaSplitLive() {
  const [rows, setRows] = useState([]);
  const [snapshotDate, setSnapshotDate] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data: latest, error: e1 } = await supabase
          .from("book_alpha_split")
          .select("snapshot_date")
          .eq("agency_id", AGENCY_ID)
          .not("snapshot_date", "is", null)
          .order("snapshot_date", { ascending: false })
          .limit(1)
          .maybeSingle();
        if (cancelled) return;
        if (e1) { setError(e1.message || "load failed"); setLoading(false); return; }
        const d = latest && latest.snapshot_date;
        if (!d) { setLoading(false); return; }
        setSnapshotDate(d);

        const { data, error: e2 } = await supabase
          .from("book_alpha_split")
          .select("letter_bucket, account_count, team_member_id, team:team_member_id(first_name, last_name)")
          .eq("agency_id", AGENCY_ID)
          .eq("snapshot_date", d)
          .order("letter_bucket", { ascending: true });
        if (cancelled) return;
        if (e2) { setError(e2.message || "load failed"); setLoading(false); return; }
        setRows(Array.isArray(data) ? data : []);
        setLoading(false);
      } catch (err) {
        if (!cancelled) { setError((err && err.message) || String(err)); setLoading(false); }
      }
    })();
    return () => { cancelled = true; };
  }, []);

  if (loading) return <p style={{ fontSize: 12.5, color: T.slate500, fontStyle: "italic", margin: 0 }}>Loading alpha split…</p>;
  if (error)   return <p style={{ fontSize: 12.5, color: "#b91c1c", margin: 0 }}>Couldn't load alpha split: {error}</p>;
  if (!rows.length) return <p style={{ fontSize: 12.5, color: T.slate500, fontStyle: "italic", margin: 0 }}>No alpha split snapshot found.</p>;

  // Group by team member. Compute range as first-letter of first bucket to last-letter of last bucket.
  let groupList = [];
  try {
    const groups = new Map();
    for (const r of rows) {
      const key = r && r.team_member_id ? r.team_member_id : "unassigned";
      if (!groups.has(key)) {
        const t = (r && r.team) || null;
        const name = t
          ? `${t.first_name || ""} ${t.last_name || ""}`.trim()
          : "Unassigned";
        groups.set(key, { name, buckets: [], total: 0 });
      }
      const g = groups.get(key);
      if (r && r.letter_bucket) g.buckets.push(String(r.letter_bucket));
      g.total += Number(r && r.account_count) || 0;
    }
    groupList = Array.from(groups.values()).sort((a, b) => {
      const ab = (a.buckets[0] || "");
      const bb = (b.buckets[0] || "");
      return ab.localeCompare(bb);
    });
  } catch (_) {
    return <p style={{ fontSize: 12.5, color: "#b91c1c", margin: 0 }}>Couldn't parse alpha split data.</p>;
  }

  const rangeOf = (buckets) => {
    if (!buckets || !buckets.length) return "";
    const first = buckets[0];
    const last = buckets[buckets.length - 1];
    const startChar = first.charAt(0);
    const endChar = last.charAt(last.length - 1);
    return startChar === endChar ? startChar : `${startChar}-${endChar}`;
  };

  return (
    <div>
      <div style={{ display: "grid", gridTemplateColumns: "1fr", rowGap: 8 }}>
        {groupList.map((g, idx) => (
          <div key={`${g.name}-${idx}`} style={{ fontSize: 13, lineHeight: 1.5, color: T.slate900 }}>
            <span style={{ fontWeight: 600 }}>{g.name}</span>
            <span style={{ color: T.slate500 }}> — </span>
            <span>{rangeOf(g.buckets)}</span>
            <span style={{ color: T.slate300, margin: "0 6px" }}>·</span>
            <span style={{ color: T.slate500 }}>{g.total.toLocaleString()} accounts</span>
          </div>
        ))}
      </div>
      {snapshotDate ? (
        <div style={{ marginTop: 10, fontSize: 11, color: T.slate500, fontStyle: "italic" }}>
          Live from <code>public.book_alpha_split</code>. Snapshot as of <strong>{snapshotDate}</strong>.
        </div>
      ) : null}
    </div>
  );
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
    panel: {
      padding: vp.isPhone ? "8px 12px 14px 12px" : "8px 24px 16px 24px",
      maxHeight: vp.isPhone ? "calc(100vh - 200px)" : "calc(100vh - 220px)",
      overflowY: "auto",
      WebkitOverflowScrolling: "touch",
    },
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
    cardBody: {
      fontSize: vp.isPhone ? 12 : 13,
      lineHeight: 1.45,
      color: T.slate900,
      letterSpacing: "-0.005em",
    },
    section: {
      marginTop: 12,
      paddingTop: 10,
      borderTop: `1px solid ${T.slate200}`,
    },
    refGrid: {
      marginTop: 12,
      paddingTop: 10,
      borderTop: `1px solid ${T.slate200}`,
      display: "grid",
      gridTemplateColumns: vp.isPhone ? "1fr" : "repeat(4, 1fr)",
      columnGap: vp.isPhone ? 0 : 20,
      rowGap: vp.isPhone ? 14 : 0,
      alignItems: "start",
    },
    refCol: {
      display: "flex",
      flexDirection: "column",
      gap: 8,
    },
    refColBlock: {
      // Used to space Who Handles What + Agency Info within the same column
      marginTop: 12,
    },
    officeInline: {
      display: "flex",
      flexDirection: "column",
      gap: 6,
      fontSize: 11,
      color: T.slate500,
    },
    sectionLabel: {
      fontSize: 10,
      fontWeight: 700,
      textTransform: "uppercase",
      letterSpacing: "0.16em",
      color: T.blue,
      marginBottom: 6,
    },
    subheading: {
      fontSize: 11,
      fontWeight: 600,
      color: T.slate700,
      marginTop: 6,
      marginBottom: 4,
    },
    natoFlow: {
      marginTop: 12,
      fontSize: 12,
      lineHeight: 1.7,
      color: T.slate700,
      letterSpacing: "0.005em",
    },
    natoWord: {
      whiteSpace: "nowrap",
    },
    natoLetterInline: {
      fontWeight: 700,
      color: T.blue,
    },
    natoSep: {
      color: T.slate300,
      margin: "0 6px",
    },

    list: {
      margin: 0,
      paddingLeft: 16,
      fontSize: 12,
      lineHeight: 1.4,
      color: T.slate900,
    },
    subList: {
      margin: "2px 0 0 0",
      paddingLeft: 16,
      fontSize: 11,
      lineHeight: 1.35,
      color: T.slate700,
    },
    office: {
      marginTop: 14,
      paddingTop: 10,
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

  const hasContact = office.phone || office.customer_email;
  const hasCodes   = office.sf_agent_code || office.txdi || office.npn || office.jackson_id;
  const hasAnyOffice = office.name || office.address || hasContact || hasCodes;

  return (
    <div style={css.wrap} aria-label="Agency identity">
      {/* Pill row: label always shows; essence hides when the ribbon is expanded */}
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
              aria-label={`${k} \u2014 ${identity[k].essence}`}
            >
              <span style={css.pillLabel}>{k}</span>
              {!expanded && <span style={css.pillEssence}>{identity[k].essence}</span>}
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
          {/* Value statements \u2014 no repeated titles; the pills above serve as headers */}
          <div style={css.grid}>
            {ORDER.map((k, idx) => (
              <div key={k} style={css.card(idx)}>
                <div style={css.cardBody}>{identity[k].body}</div>
              </div>
            ))}
          </div>

          {/* Reference sections — 4 columns on desktop, stacked on phone */}
          <div style={css.refGrid}>

            {/* Column 1: Rules of the Road */}
            <div style={css.refCol}>
              <div style={css.sectionLabel}>Rules of the Road</div>
              {RULES_OF_ROAD.map((s) => (
                <div key={s.heading}>
                  <div style={css.subheading}>{s.heading}</div>
                  <ul style={css.list}>
                    {s.items.map((it, i) => (
                      <li key={i}>
                        {it.emphasis && <strong>{it.emphasis}</strong>}{it.emphasis ? " " : ""}{it.rest}
                        {it.sub && (
                          <ul style={css.subList}>
                            {it.sub.map((s2, j) => <li key={j}>{s2}</li>)}
                          </ul>
                        )}
                      </li>
                    ))}
                  </ul>
                </div>
              ))}
            </div>

            {/* Column 2: When You Get Stuck */}
            <div style={css.refCol}>
              <div style={css.sectionLabel}>When You Get Stuck</div>
              {WHEN_STUCK.map((s) => (
                <div key={s.heading}>
                  <div style={css.subheading}>{s.heading}</div>
                  <ol style={css.list}>
                    {s.items.map((it, i) => <li key={i}>{it}</li>)}
                  </ol>
                </div>
              ))}
            </div>

            {/* Column 3: NATO Phonetic Alphabet (no label, inline flow with bold first letter) */}
            <div style={css.refCol}>
              <div style={css.natoFlow}>
                {NATO.map((word, i) => (
                  <span key={word} style={css.natoWord}>
                    <span style={css.natoLetterInline}>{word.charAt(0)}</span>{word.slice(1)}
                    {i < NATO.length - 1 && <span style={css.natoSep}>{"\u00b7"}</span>}
                  </span>
                ))}
              </div>
            </div>

            {/* Column 4: Who Handles What + Agency Info */}
            <div style={css.refCol}>
              <div style={css.sectionLabel}>Who Handles What</div>
              <AlphaSplitLive />

              {hasAnyOffice && (
                <div style={css.refColBlock}>
                  <div style={css.sectionLabel}>Agency Info</div>
                  <div style={css.officeInline}>
                    {(office.name || office.address) && (
                      <div>
                        {office.name && <span style={css.officeName}>{office.name}</span>}
                        {office.name && office.address && <span style={css.dot}>{"\u00b7"}</span>}
                        {office.address && <span>{office.address}</span>}
                      </div>
                    )}
                    {hasContact && (
                      <div>
                        {office.phone && <><span style={css.officeLabel}>Phone</span><span>{office.phone}</span></>}
                        {office.phone && office.customer_email && <span style={css.dot}>{"\u00b7"}</span>}
                        {office.customer_email && <><span style={css.officeLabel}>Customer Email</span><span>{office.customer_email}</span></>}
                      </div>
                    )}
                    {hasCodes && (
                      <div>
                        {office.sf_agent_code && <><span style={css.officeLabel}>SF Agent</span><span>{office.sf_agent_code}</span></>}
                        {office.sf_agent_code && office.txdi && <span style={css.dot}>{"\u00b7"}</span>}
                        {office.txdi && <><span style={css.officeLabel}>TXDI</span><span>{office.txdi}</span></>}
                        {(office.sf_agent_code || office.txdi) && office.npn && <span style={css.dot}>{"\u00b7"}</span>}
                        {office.npn && <><span style={css.officeLabel}>NPN</span><span>{office.npn}</span></>}
                        {(office.sf_agent_code || office.txdi || office.npn) && office.jackson_id && <span style={css.dot}>{"\u00b7"}</span>}
                        {office.jackson_id && <><span style={css.officeLabel}>Jackson ID</span><span>{office.jackson_id}</span></>}
                      </div>
                    )}
                  </div>
                </div>
              )}
            </div>

          </div>
        </div>
      )}
    </div>
  );
}
