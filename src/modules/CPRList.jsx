import { useState, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { T } from "../lib/theme.js";

// ============================================================
// CPR LIST — Sidebar-routed index of past Weekly CPR Recaps
// Reachable via sidebar item "CPR"; click a row to open /cpr/YYYY-MM-DD
// Read-only summary list; full detail/edit happens on /cpr/{date} page.
// ============================================================

// ── Date helpers ───────────────────────────────────────────────────────────────
function isValidISODate(s) {
  return typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
}
function fmtDateLong(iso) {
  if (!isValidISODate(iso)) return "—";
  try {
    return new Date(iso + "T00:00:00").toLocaleDateString("en-US", {
      weekday: "long", month: "long", day: "numeric", year: "numeric",
    });
  } catch { return iso; }
}
function fmtRange(satISO) {
  if (!isValidISODate(satISO)) return "—";
  try {
    const end = new Date(satISO + "T00:00:00");
    const start = new Date(end);
    start.setDate(end.getDate() - 6);
    const opts = { month: "short", day: "numeric" };
    return `${start.toLocaleDateString("en-US", opts)} – ${end.toLocaleDateString("en-US", opts)}`;
  } catch { return satISO; }
}

// ── Formatters ─────────────────────────────────────────────────────────────────
const fmtInt = (n) => {
  if (n === null || n === undefined || n === "") return "—";
  const v = Number(n);
  if (!isFinite(v)) return "—";
  return Math.round(v).toLocaleString("en-US");
};

// ── Layout primitives (kept local to avoid coupling with CPRDetail) ────────────
const Card = ({ children, style = {} }) => (
  <div style={{
    background: T.white, borderRadius: 12,
    border: `1px solid ${T.slate200}`,
    padding: "18px 20px", ...style,
  }}>{children}</div>
);

const Th = ({ children, align = "left", style = {} }) => (
  <th style={{
    padding: "10px 12px", fontSize: 10, fontWeight: 700, color: T.slate500,
    textTransform: "uppercase", letterSpacing: 0.4, textAlign: align,
    borderBottom: `1px solid ${T.slate200}`, whiteSpace: "nowrap",
    background: T.slate50, ...style,
  }}>{children}</th>
);

const Td = ({ children, align = "left", style = {} }) => (
  <td style={{
    padding: "12px", fontSize: 13, color: T.slate800,
    textAlign: align, borderBottom: `1px solid ${T.slate100}`,
    fontVariantNumeric: "tabular-nums", ...style,
  }}>{children}</td>
);

// ── Navigation helper ──────────────────────────────────────────────────────────
// Pushes /cpr/{date} into history and dispatches popstate so the BCC shell's
// detectCPRWeekDate logic picks it up without a full page reload.
function openCPR(weekDate) {
  if (typeof window === "undefined") return;
  window.history.pushState({}, "", `/cpr/${weekDate}`);
  window.dispatchEvent(new PopStateEvent("popstate"));
}

// ── Main component ─────────────────────────────────────────────────────────────
export default function CPRList() {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "16px" : _vp.isTablet ? "20px 18px 40px" : "30px 30px 60px";

  const [state, setState] = useState({
    loading: true,
    error: null,
    reports: [],
  });

  useEffect(() => {
    if (!supabase) return;
    let cancelled = false;
    async function load() {
      try {
        const { data, error } = await supabase
          .from("weekly_cpr_reports")
          .select(`
            id, week_ending_date, notes,
            quotes_total_net, quotes_owed_next_week,
            quarterly_sales_points_qtd, quarterly_sales_points_target,
            won_the_week, non_pays, open_claims, new_claims
          `)
          .eq("agency_id", AGENCY_ID)
          .order("week_ending_date", { ascending: false })
          .limit(104);
        if (cancelled) return;
        if (error) {
          setState({ loading: false, error: error.message, reports: [] });
          return;
        }
        setState({ loading: false, error: null, reports: data || [] });
      } catch (err) {
        if (!cancelled) {
          setState({ loading: false, error: err?.message || "Failed to load CPR Recaps", reports: [] });
        }
      }
    }
    load();
    return () => { cancelled = true; };
  }, []);

  // Notes preview (first ~110 chars of opener)
  const previewNotes = (notes) => {
    if (!notes) return null;
    const trimmed = notes.trim();
    if (!trimmed) return null;
    return trimmed.length > 110 ? trimmed.slice(0, 110) + "…" : trimmed;
  };

  // Header block (used by all states for consistency)
  const Header = () => (
    <div style={{ marginBottom: 24 }}>
      <div style={{
        fontSize: 22, fontWeight: 800, color: T.slate900, letterSpacing: "-0.02em",
      }}>📊 CPR Recaps</div>
      <div style={{ fontSize: 13, color: T.slate500, marginTop: 6, lineHeight: 1.6 }}>
        Weekly Customer Performance Reports — most recent first. Click any row to open the full recap.
      </div>
    </div>
  );

  if (state.loading) {
    return (
      <div style={{ maxWidth: 1100, margin: "0 auto", padding: _pad }}>
        <Header />
        <Card>
          <div style={{ fontSize: 13, color: T.slate500 }}>Loading CPR Recaps…</div>
        </Card>
      </div>
    );
  }

  if (state.error) {
    return (
      <div style={{ maxWidth: 1100, margin: "0 auto", padding: _pad }}>
        <Header />
        <Card>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.red, marginBottom: 8 }}>
            Couldn't load CPR Recaps
          </div>
          <div style={{ fontSize: 12, color: T.slate600 }}>{state.error}</div>
        </Card>
      </div>
    );
  }

  if (state.reports.length === 0) {
    return (
      <div style={{ maxWidth: 1100, margin: "0 auto", padding: _pad }}>
        <Header />
        <Card>
          <div style={{ fontSize: 13, color: T.slate600, lineHeight: 1.7 }}>
            No CPR Recaps in the system yet. The first weekly recap will appear here once it's generated by the Saturday automation.
          </div>
        </Card>
      </div>
    );
  }

  return (
    <div style={{ maxWidth: 1100, margin: "0 auto", padding: _pad }}>
      <Header />

      <div style={{
        background: T.white, borderRadius: 12,
        border: `1px solid ${T.slate200}`, overflow: "hidden",
      }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 780 }}>
            <thead>
              <tr>
                <Th>Week ending</Th>
                <Th align="right">Quotes net</Th>
                <Th align="right">Owed next wk</Th>
                <Th align="right">Sales pts QTD</Th>
                <Th align="center">WtW</Th>
                <Th>Opener preview</Th>
              </tr>
            </thead>
            <tbody>
              {state.reports.map(r => {
                const preview = previewNotes(r.notes);
                const wtw = r.won_the_week;
                return (
                  <tr
                    key={r.id}
                    onClick={() => openCPR(r.week_ending_date)}
                    style={{ cursor: "pointer" }}
                    onMouseEnter={e => { e.currentTarget.style.background = T.slate50; }}
                    onMouseLeave={e => { e.currentTarget.style.background = "transparent"; }}
                  >
                    <Td>
                      <div style={{ fontWeight: 600, color: T.slate900 }}>
                        {fmtDateLong(r.week_ending_date)}
                      </div>
                      <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
                        {fmtRange(r.week_ending_date)}
                      </div>
                    </Td>
                    <Td align="right">{fmtInt(r.quotes_total_net)}</Td>
                    <Td align="right" style={{ fontWeight: 700, color: T.slate900 }}>
                      {fmtInt(r.quotes_owed_next_week)}
                    </Td>
                    <Td align="right">
                      {r.quarterly_sales_points_qtd != null
                        ? Number(r.quarterly_sales_points_qtd).toFixed(2)
                        : "—"}
                      {r.quarterly_sales_points_target ? (
                        <span style={{ color: T.slate500 }}>
                          {" / " + Number(r.quarterly_sales_points_target).toFixed(2)}
                        </span>
                      ) : null}
                    </Td>
                    <Td align="center" style={{ fontSize: 16 }}>
                      {wtw === true ? "✅" : wtw === false ? "❌" : "—"}
                    </Td>
                    <Td style={{
                      maxWidth: 280, color: T.slate600, fontSize: 12, lineHeight: 1.5,
                    }}>
                      {preview ? preview : (
                        <span style={{ color: T.slate400, fontStyle: "italic" }}>No opener yet</span>
                      )}
                    </Td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        <div style={{
          padding: "10px 16px", borderTop: `1px solid ${T.slate100}`,
          fontSize: 11, color: T.slate500,
        }}>
          Showing {state.reports.length} most recent {state.reports.length === 1 ? "recap" : "recaps"}.
        </div>
      </div>
    </div>
  );
}
