import { useState } from "react";
import { useViewport } from "../lib/hooks.js";
import { TOKENS } from "../lib/theme.js";

// ============================================================
// ONBOARDING PREVIEW — concept mockup
// Not connected to real hire data. Demonstrates the three-view
// pattern: master template with role tags → filtered per-hire
// snapshots (Reception + AM). Preview only. Real page build
// (instantiate_onboarding SQL function, personal snapshot rows,
// tag-based filter renderer) is a future session.
// ============================================================

const TAG_STYLES = {
  ALL:       { bg: "#e5e5ea", fg: "#48484a" },
  SALES:     { bg: "#d1e9ff", fg: "#0451a5" },
  RETENTION: { bg: "#d1f2d9", fg: "#1b5e20" },
};

const Tag = ({ kind }) => {
  const s = TAG_STYLES[kind] || TAG_STYLES.ALL;
  return (
    <span style={{
      display: "inline-block",
      fontSize: 10,
      padding: "2px 6px",
      borderRadius: 4,
      marginRight: 8,
      fontWeight: 700,
      letterSpacing: "0.3px",
      background: s.bg,
      color: s.fg,
      verticalAlign: "middle",
    }}>{kind}</span>
  );
};

const Item = ({ tag, text, showTag }) => (
  <div style={{
    display: "flex",
    alignItems: "flex-start",
    gap: 10,
    padding: "8px 0",
    fontSize: 14,
    borderTop: `1px solid ${TOKENS.slate100 || "#f0f0f2"}`,
  }}>
    <div style={{
      width: 16, height: 16,
      border: `1.5px solid ${TOKENS.slate400 || "#86868b"}`,
      borderRadius: 4,
      flexShrink: 0,
      marginTop: 2,
      background: "#fff",
    }} />
    <div style={{ flex: 1 }}>
      {showTag && <Tag kind={tag} />}
      {text}
    </div>
  </div>
);

const IncludeBlock = ({ token, expanded, resolved }) => (
  <div style={{
    background: expanded ? "#fff" : "#f0f4f8",
    borderLeft: `3px solid ${expanded ? "#007aff" : "#86868b"}`,
    padding: "10px 12px",
    margin: "10px 0",
    borderRadius: 4,
    fontSize: 13,
    fontStyle: expanded ? "normal" : "italic",
    color: expanded ? "#1d1d1f" : "#4a4a4f",
  }}>
    {expanded ? resolved : token}
  </div>
);

export default function OnboardingPreview() {
  // hooks-before-returns (rule 22)
  const _vp = useViewport();
  const [view, setView] = useState("master");

  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const _maxWidth = _vp.isPhone ? "100%" : "720px";

  const tabBtn = (id, label) => {
    const isActive = view === id;
    return (
      <button
        key={id}
        onClick={() => setView(id)}
        style={{
          flex: 1,
          padding: "10px 12px",
          border: "none",
          background: isActive ? "#fff" : "transparent",
          borderRadius: 7,
          fontSize: 13,
          fontWeight: 600,
          cursor: "pointer",
          color: "#1d1d1f",
          boxShadow: isActive ? "0 1px 3px rgba(0,0,0,0.1)" : "none",
          whiteSpace: "nowrap",
          flexShrink: 0,
        }}
      >{label}</button>
    );
  };

  const card = {
    background: "#fff",
    borderRadius: 10,
    padding: _vp.isPhone ? "16px" : "20px",
    border: `1px solid ${TOKENS.slate200 || "#e0e0e5"}`,
  };
  const cardCaption = { fontSize: 12, color: "#6b6b70", marginBottom: 14 };
  const cardTitle = { fontSize: 17, fontWeight: 700, marginBottom: 4 };
  const footnote = {
    fontSize: 12,
    color: "#6b6b70",
    marginTop: 14,
    paddingTop: 12,
    borderTop: `1px solid ${TOKENS.slate100 || "#f0f0f2"}`,
  };

  return (
    <div style={{
      padding: _pad,
      maxWidth: _maxWidth,
      margin: "0 auto",
    }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>
        Onboarding — one template, three views
      </h1>
      <p style={{ fontSize: 13, color: "#6b6b70", marginBottom: 18 }}>
        Concept preview. Not wired to real hire data yet. Master template edits once, each new hire gets a filtered snapshot by role.
      </p>

      {/* Segmented tab control */}
      <div style={{
        display: "flex",
        gap: 6,
        marginBottom: 18,
        background: "#e8e8ed",
        padding: 4,
        borderRadius: 10,
        overflowX: "auto",
        whiteSpace: "nowrap",
      }}>
        {tabBtn("master",    "Master")}
        {tabBtn("retention", "Reception view")}
        {tabBtn("sales",     "AM view")}
      </div>

      {/* MASTER */}
      {view === "master" && (
        <div style={card}>
          <div style={cardTitle}>New Team Member — Master Template</div>
          <div style={cardCaption}>Peter's edit surface. Tags visible. Includes shown as tokens.</div>
          <Item tag="ALL"       text="Watch Peter's Ten"                    showTag />
          <Item tag="ALL"       text="Compliance floor briefing"            showTag />
          <IncludeBlock token="{{include: 02 Tech Setup — new-hire portion}}" />
          <Item tag="SALES"     text="Shadow 5 quotes this week"            showTag />
          <Item tag="RETENTION" text="Answer inbounds by 3rd ring"          showTag />
          <div style={footnote}>
            ALL stays everywhere · SALES → AM view only · RETENTION → Reception view only · include resolves at instantiation into a frozen snapshot on the hire's personal page
          </div>
        </div>
      )}

      {/* RETENTION */}
      {view === "retention" && (
        <div style={card}>
          <div style={cardTitle}>Cassie — New Reception Setup</div>
          <div style={cardCaption}>Instantiated snapshot. No tags visible. SALES items filtered out.</div>
          <Item text="Watch Peter's Ten" />
          <Item text="Compliance floor briefing" />
          <IncludeBlock expanded resolved="Yubikey + VPN + Jabber + Outlook signature + printer added (snapshot of 02 Tech Setup)" />
          <Item text="Answer inbounds by 3rd ring" />
          <div style={footnote}>
            Cassie checks her own copy. Source pages never touched. Template updates only affect future hires.
          </div>
        </div>
      )}

      {/* SALES */}
      {view === "sales" && (
        <div style={card}>
          <div style={cardTitle}>John — New Account Manager Setup</div>
          <div style={cardCaption}>Instantiated snapshot. No tags visible. RETENTION items filtered out.</div>
          <Item text="Watch Peter's Ten" />
          <Item text="Compliance floor briefing" />
          <IncludeBlock expanded resolved="Yubikey + VPN + Jabber + Outlook signature + printer added (snapshot of 02 Tech Setup)" />
          <Item text="Shadow 5 quotes this week" />
          <div style={footnote}>
            Same source, John's own filtered copy.
          </div>
        </div>
      )}
    </div>
  );
}
