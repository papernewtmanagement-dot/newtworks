import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import ComplianceCenter from "./ComplianceCenter.jsx";

// ============================================================
// BCC CORE PRINCIPLES MODULE v1.0
// Business Command Center — State Farm Agent Edition
//
// PURPOSE:
// The agency's governing principles — the authority layer that
// sits above persistent_memory and above any in-conversation
// instruction. Scripture (priority 200) governs. Then Claude
// directives (110). Then Operating Philosophy (100).
//
// This module is READ-ONLY by design. These are the rules of
// the road. They don't get casually edited. Changes happen
// through a deliberate conversation with Claude, who writes
// the SQL.
// ============================================================

// ─── Design Tokens ────────────────────────────────────────────
import { T } from "../lib/theme.js";

// ─── Domain Metadata ──────────────────────────────────────────
// Visual config per known domain. Domains not in this map fall
// back to DEFAULT_DOMAIN_META.
const DOMAIN_META = {
  scripture:           { icon: "✝️",  accent: T.gold,   accentLt: T.goldLt,   tagline: "The final authority" },
  claude_directives:   { icon: "🛡️",  accent: T.slate900,   accentLt: T.slate100,   tagline: "Things Claude must never break" },
  operating_philosophy:{ icon: "🧭",  accent: T.green,  accentLt: T.greenLt,  tagline: "How Peter and the agency operate" },
  team_model:          { icon: "👥",  accent: T.purple, accentLt: T.purpleLt, tagline: "How the team is structured" },
  compliance:          { icon: "⚖️",  accent: T.red,    accentLt: T.redLt,    tagline: "Non-negotiable rules" },
};
const DEFAULT_DOMAIN_META = { icon: "📜", accent: T.slate600, accentLt: T.slate100, tagline: "" };
const metaFor = (domain) => DOMAIN_META[domain] || DEFAULT_DOMAIN_META;
const prettyDomain = (d) => (d || "").replace(/_/g, " ").replace(/\b\w/g, c => c.toUpperCase());

// ─── Lightweight Markdown Renderer ────────────────────────────
// Handles: # / ## / ### headings, **bold**, *italic*, `code`,
// - bullets, paragraphs. No deps. Keeps the bundle small.
function renderInline(text) {
  if (typeof text !== "string") return text;
  // Split on bold/italic/code while preserving delimiters
  const parts = [];
  const regex = /(\*\*[^*]+\*\*|__[^_]+__|\*[^*]+\*|_[^_]+_|`[^`]+`)/g;
  let lastIdx = 0;
  let m;
  let key = 0;
  while ((m = regex.exec(text)) !== null) {
    if (m.index > lastIdx) parts.push(text.slice(lastIdx, m.index));
    const tok = m[0];
    if (tok.startsWith("**") || tok.startsWith("__")) {
      parts.push(<strong key={`b${key++}`} style={{ fontWeight: 700, color: T.slate900 }}>{tok.slice(2, -2)}</strong>);
    } else if (tok.startsWith("`")) {
      parts.push(<code key={`c${key++}`} style={{ background: T.slate100, padding: "1px 6px", borderRadius: 4, fontSize: "0.92em", fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", color: T.slate800 }}>{tok.slice(1, -1)}</code>);
    } else {
      parts.push(<em key={`i${key++}`} style={{ fontStyle: "italic" }}>{tok.slice(1, -1)}</em>);
    }
    lastIdx = m.index + tok.length;
  }
  if (lastIdx < text.length) parts.push(text.slice(lastIdx));
  return parts;
}

function MarkdownView({ content, accent }) {
  const blocks = useMemo(() => {
    const raw = String(content || "");
    const lines = raw.split(/\r?\n/);
    const out = [];
    let para = [];
    let list = null; // { items: [] }
    const flushPara = () => { if (para.length) { out.push({ type: "p", text: para.join(" ") }); para = []; } };
    const flushList = () => { if (list) { out.push({ type: "ul", items: list.items }); list = null; } };
    for (const rawLine of lines) {
      const line = rawLine.replace(/\s+$/, "");
      if (!line.trim()) { flushPara(); flushList(); continue; }
      const h = /^(#{1,4})\s+(.*)$/.exec(line);
      if (h) { flushPara(); flushList(); out.push({ type: "h", level: h[1].length, text: h[2] }); continue; }
      const li = /^[-*]\s+(.*)$/.exec(line);
      if (li) { flushPara(); if (!list) list = { items: [] }; list.items.push(li[1]); continue; }
      flushList();
      para.push(line.replace(/^\s+/, ""));
    }
    flushPara(); flushList();
    return out;
  }, [content]);

  return (
    <div style={{ fontSize: 14, lineHeight: 1.75, color: T.slate700 }}>
      {blocks.map((b, i) => {
        if (b.type === "h") {
          const sizes = { 1: 24, 2: 18, 3: 15, 4: 14 };
          const weights = { 1: 800, 2: 700, 3: 700, 4: 600 };
          const mt = i === 0 ? 0 : (b.level <= 2 ? 28 : 18);
          return (
            <div key={i} style={{ marginTop: mt, marginBottom: 10, fontSize: sizes[b.level] || 14, fontWeight: weights[b.level] || 600, color: T.slate900, letterSpacing: b.level === 1 ? "-0.02em" : "-0.01em" }}>
              {b.level === 2 ? (
                <span style={{ display: "inline-block", borderLeft: `3px solid ${accent}`, paddingLeft: 10 }}>{renderInline(b.text)}</span>
              ) : renderInline(b.text)}
            </div>
          );
        }
        if (b.type === "ul") {
          return (
            <ul key={i} style={{ margin: "8px 0 14px 0", paddingLeft: 22, listStyle: "disc" }}>
              {b.items.map((it, j) => (
                <li key={j} style={{ marginBottom: 6 }}>{renderInline(it)}</li>
              ))}
            </ul>
          );
        }
        return (
          <p key={i} style={{ margin: "0 0 14px 0" }}>{renderInline(b.text)}</p>
        );
      })}
    </div>
  );
}

// ─── Ask Claude Button (mirrors PersistentMemory.jsx pattern) ─
const AskBtn = ({ context, label = "Ask Claude about this", size = "normal" }) => (
  <button
    onClick={() => { navigator.clipboard?.writeText(context); window.open("https://claude.ai", "_blank"); }}
    style={{
      display: "inline-flex", alignItems: "center", gap: 6,
      background: T.blue, color: T.white,
      border: "none", borderRadius: 7,
      padding: size === "small" ? "5px 10px" : "8px 14px",
      fontSize: size === "small" ? 11 : 12,
      fontWeight: 600, cursor: "pointer",
      transition: "background 0.15s",
    }}
    onMouseOver={(e) => { e.currentTarget.style.background = T.slate900; }}
    onMouseOut={(e) => { e.currentTarget.style.background = T.blue; }}
    title="Copy this principle to clipboard and open Claude.ai"
  >
    💬 {label}
  </button>
);

// ─── Module ───────────────────────────────────────────────────
function PrinciplesView() {
  const [principles, setPrinciples] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [selectedId, setSelectedId] = useState(null);
  const _vp = useViewport();

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        setLoading(true);
        const { data, error: qErr } = await supabase
          .from("core_principles")
          .select("id, domain, title, priority, content, books_referenced, is_active, updated_at")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true)
          .order("priority", { ascending: false });
        if (cancelled) return;
        if (qErr) { setError(qErr.message); setPrinciples([]); }
        else {
          const rows = Array.isArray(data) ? data : [];
          setPrinciples(rows);
          if (rows.length && !selectedId && !(typeof window !== "undefined" && window.innerWidth < 640)) setSelectedId(rows[0].id);
        }
      } catch (e) {
        if (!cancelled) { setError(e?.message || "Failed to load core principles"); setPrinciples([]); }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const selected = useMemo(
    () => (principles || []).find(p => p.id === selectedId) || null,
    [principles, selectedId]
  );

  // ─── Loading / Empty / Error ──────────────────────────────
  if (loading) {
    return (
      <div style={{ padding: 40, color: T.slate500, fontSize: 14 }}>
        Loading core principles…
      </div>
    );
  }

  if (error) {
    return (
      <div style={{ padding: 40 }}>
        <div style={{ background: T.redLt, color: T.red, padding: 16, borderRadius: 10, fontSize: 13, border: `1px solid ${T.red}33` }}>
          <strong>Could not load core principles.</strong><br />
          {error}
        </div>
      </div>
    );
  }

  if (!principles.length) {
    return (
      <div style={{ padding: 40 }}>
        <div style={{ background: T.slate50, padding: 24, borderRadius: 12, border: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 6 }}>No core principles yet</div>
          <div style={{ fontSize: 13, color: T.slate600, lineHeight: 1.6 }}>
            Core principles are the governing rules of the agency — they sit above session notes and persistent memory.
            Ask Claude to draft one and we'll insert it together.
          </div>
        </div>
      </div>
    );
  }

  // ─── Layout ───────────────────────────────────────────────
  return (
    <div style={{ display: "flex", height: "100%", background: T.slate50 }}>
      {/* Sidebar */}
      {/* Phone: full-width when nothing selected; hidden when reading.   */}
      {/* Tablet/desktop: persistent 320px panel as before.               */}
      {(!_vp.isPhone || !selectedId) && (
      <div style={{
        width: _vp.isPhone ? "100%" : 320,
        borderRight: _vp.isPhone ? "none" : `1px solid ${T.slate200}`,
        background: T.white, display: "flex", flexDirection: "column"
      }}>
        {/* Header */}
        <div style={{ padding: "20px 20px 16px 20px", borderBottom: `1px solid ${T.slate200}` }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 4 }}>
            The Authority Layer
          </div>
          <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900, letterSpacing: "-0.02em" }}>
            Core Principles
          </div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 6, lineHeight: 1.5 }}>
            Read at the start of every Claude session. Outranks session notes and any in-conversation instruction that conflicts.
          </div>
        </div>

        {/* Principle list — sorted by priority DESC (Scripture first) */}
        <div style={{ flex: 1, overflowY: "auto", padding: "10px 0" }}>
          {principles.map((p) => {
            const m = metaFor(p.domain);
            const isActive = p.id === selectedId;
            return (
              <button
                key={p.id}
                onClick={() => setSelectedId(p.id)}
                style={{
                  width: "100%",
                  textAlign: "left",
                  background: isActive ? m.accentLt : "transparent",
                  border: "none",
                  borderLeft: isActive ? `3px solid ${m.accent}` : "3px solid transparent",
                  padding: "12px 17px",
                  cursor: "pointer",
                  display: "flex",
                  gap: 11,
                  alignItems: "flex-start",
                  transition: "background 0.15s",
                }}
                onMouseOver={(e) => { if (!isActive) e.currentTarget.style.background = T.slate50; }}
                onMouseOut={(e) => { if (!isActive) e.currentTarget.style.background = "transparent"; }}
              >
                <div style={{ fontSize: 20, lineHeight: 1, marginTop: 2 }}>{m.icon}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 3 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, letterSpacing: "-0.01em" }}>
                      {prettyDomain(p.domain)}
                    </div>
                    <div style={{ fontSize: 10, fontWeight: 700, color: m.accent, background: m.accentLt, padding: "1px 6px", borderRadius: 4 }}>
                      {p.priority ?? "—"}
                    </div>
                  </div>
                  <div style={{ fontSize: 11, color: T.slate500, lineHeight: 1.4 }}>
                    {m.tagline || (p.title || "").slice(0, 60)}
                  </div>
                </div>
              </button>
            );
          })}
        </div>

        {/* Footer: how this gets edited */}
        <div style={{ padding: "14px 18px", borderTop: `1px solid ${T.slate200}`, background: T.slate50 }}>
          <div style={{ fontSize: 11, color: T.slate500, lineHeight: 1.5 }}>
            <strong style={{ color: T.slate700 }}>Read-only here.</strong> To revise a principle, talk to Claude — Claude writes the SQL after you've reasoned through the change together.
          </div>
        </div>
      </div>
      )}

      {/* Main pane */}
      {/* Phone: full-width with sticky back button when reading. */}
      {(!_vp.isPhone || selectedId) && (
      <div style={{ flex: 1, overflowY: "auto" }}>
        {_vp.isPhone && selectedId && (
          <div style={{
            position: "sticky", top: 0, zIndex: 10,
            background: T.white,
            borderBottom: `1px solid ${T.slate200}`,
            padding: "10px 14px",
            display: "flex", alignItems: "center", gap: 8,
          }}>
            <button
              type="button"
              onClick={() => setSelectedId(null)}
              style={{
                display: "flex", alignItems: "center", gap: 6,
                background: "transparent",
                border: `1px solid ${T.slate200}`,
                borderRadius: 8,
                padding: "7px 12px",
                fontSize: 13, fontWeight: 600,
                color: T.slate700, cursor: "pointer",
              }}
              aria-label="Back to principles"
            >
              <span aria-hidden="true">‹</span> Back
            </button>
            <div style={{
              fontSize: 12, fontWeight: 600, color: T.slate500,
              overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
            }}>
              {prettyDomain(selected?.domain)}
            </div>
          </div>
        )}
        {selected && (
          <PrincipleDetail principle={selected} />
        )}
      </div>
      )}
    </div>
  );
}

// ─── Detail View ──────────────────────────────────────────────
function PrincipleDetail({ principle }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "20px 16px 48px" : _vp.isTablet ? "26px 24px 60px" : "32px 40px 80px 40px";

  const m = metaFor(principle?.domain);
  const books = Array.isArray(principle?.books_referenced) ? principle.books_referenced : [];
  const askContext = useMemo(() => {
    return `I'm looking at this core principle on my BCC:

DOMAIN: ${principle?.domain}
TITLE: ${principle?.title}
PRIORITY: ${principle?.priority}

CONTENT:
${principle?.content || ""}

What I'd like to discuss:
`;
  }, [principle]);

  const updated = principle?.updated_at ? new Date(principle.updated_at) : null;
  const updatedStr = updated && !isNaN(updated)
    ? updated.toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" })
    : null;

  return (
    <div style={{ maxWidth: 880, margin: "0 auto", padding: _pad }}>
      {/* Title block */}
      <div style={{ display: "flex", gap: 16, alignItems: "flex-start", marginBottom: 24 }}>
        <div style={{ fontSize: 44, lineHeight: 1 }}>{m.icon}</div>
        <div style={{ flex: 1 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6, flexWrap: "wrap" }}>
            <div style={{
              fontSize: 10, fontWeight: 800, color: m.accent,
              textTransform: "uppercase", letterSpacing: "0.1em",
              background: m.accentLt, padding: "3px 10px", borderRadius: 999,
            }}>
              {prettyDomain(principle?.domain)}
            </div>
            <div style={{ fontSize: 11, fontWeight: 700, color: T.slate500 }}>
              Priority {principle?.priority ?? "—"}
            </div>
            {updatedStr && (
              <div style={{ fontSize: 11, color: T.slate400 }}>
                • Updated {updatedStr}
              </div>
            )}
          </div>
          <h1 style={{ fontSize: 28, fontWeight: 800, color: T.slate900, margin: 0, letterSpacing: "-0.025em", lineHeight: 1.25 }}>
            {principle?.title || "Untitled principle"}
          </h1>
          {m.tagline && (
            <div style={{ fontSize: 14, color: T.slate500, marginTop: 8, fontStyle: "italic" }}>
              {m.tagline}
            </div>
          )}
        </div>
      </div>

      {/* Accent bar */}
      <div style={{ height: 4, background: m.accent, borderRadius: 2, marginBottom: 28, opacity: 0.85 }} />

      {/* Content */}
      <div style={{ background: T.white, padding: "32px 36px", borderRadius: 14, border: `1px solid ${T.slate200}`, boxShadow: "0 1px 3px rgba(15, 23, 42, 0.04)" }}>
        <MarkdownView content={principle?.content || ""} accent={m.accent} />
      </div>

      {/* Books referenced */}
      {books.length > 0 && (
        <div style={{ marginTop: 28 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 12 }}>
            Books & Sources Referenced
          </div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
            {books.map((b, i) => {
              const title = b?.title || "Untitled";
              const authors = b?.authors || "";
              const note = b?.note || "";
              return (
                <div
                  key={i}
                  title={[authors, note].filter(Boolean).join(" — ")}
                  style={{
                    background: T.white,
                    border: `1px solid ${T.slate200}`,
                    borderRadius: 8,
                    padding: "8px 12px",
                    fontSize: 12,
                    color: T.slate700,
                    maxWidth: 320,
                  }}
                >
                  <div style={{ fontWeight: 600, color: T.slate900 }}>{title}</div>
                  {authors && (
                    <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>{authors}</div>
                  )}
                  {note && (
                    <div style={{ fontSize: 11, color: T.amber, fontStyle: "italic", marginTop: 2 }}>{note}</div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Action row */}
      <div style={{ marginTop: 32, paddingTop: 24, borderTop: `1px solid ${T.slate200}`, display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" }}>
        <AskBtn context={askContext} />
        <div style={{ fontSize: 11, color: T.slate500 }}>
          Copies this principle to your clipboard and opens Claude.ai. Paste, then ask away.
        </div>
      </div>
    </div>
  );
}


// ─── Outer Tabbed Shell ───────────────────────────────────────
// Top-level Core Principles module: governs all session behavior
// (principles tab) AND hosts the operational compliance tooling
// (compliance tab — wraps the existing ComplianceCenter module).
export default function CorePrinciples() {
  const [outerTab, setOuterTab] = useState("principles");
  const tabs = [
    { id: "principles", label: "Principles",        icon: "📜" },
    { id: "compliance", label: "Compliance Center", icon: "⚖️" },
  ];
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", background: T.slate50, minHeight: 0 }}>
      {/* Outer tab bar */}
      <div style={{ display: "flex", gap: 2, padding: "10px 16px 0 16px", background: T.white, borderBottom: `1px solid ${T.slate200}`, flexShrink: 0, overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
        {tabs.map(t => {
          const isActive = outerTab === t.id;
          return (
            <button
              key={t.id}
              onClick={() => setOuterTab(t.id)}
              style={{
                display: "inline-flex", alignItems: "center", gap: 6,
                padding: "9px 16px 11px 16px",
                fontSize: 13, fontWeight: 600,
                color: isActive ? T.slate900 : T.slate500,
                background: "transparent",
                border: "none",
                borderBottom: isActive ? `2px solid ${T.slate900}` : "2px solid transparent",
                marginBottom: -1,
                cursor: "pointer",
                transition: "color 0.15s",
              }}
              onMouseOver={(e) => { if (!isActive) e.currentTarget.style.color = T.slate700; }}
              onMouseOut={(e) => { if (!isActive) e.currentTarget.style.color = T.slate500; }}
            >
              <span style={{ fontSize: 14, lineHeight: 1 }}>{t.icon}</span>
              {t.label}
            </button>
          );
        })}
      </div>

      {/* Active tab content */}
      <div style={{ flex: 1, minHeight: 0, overflow: "auto" }}>
        {outerTab === "principles" && <PrinciplesView />}
        {outerTab === "compliance" && (
          <div style={{ padding: 18 }}>
            <ComplianceCenter />
          </div>
        )}
      </div>
    </div>
  );
}
