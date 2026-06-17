 import { useState, useEffect, createContext, useContext } from "react";

import Dashboard from "./src/modules/Dashboard.jsx";
import Financials from "./src/modules/Financials.jsx";
import PersistentMemory from "./src/modules/PersistentMemory.jsx";
import ComplianceCenter from "./src/modules/ComplianceCenter.jsx";
import Automations from "./src/modules/Automations.jsx";
import SocialMedia from "./src/modules/SocialMedia.jsx";
import TasksGoals from "./src/modules/TasksGoals.jsx";
import AlertsNotifications from "./src/modules/AlertsNotifications.jsx";
import Documents from "./src/modules/Documents.jsx";
import HRPeople from "./src/modules/HRPeople.jsx";
import Settings from "./src/modules/Settings.jsx";
import MonthlyClose from "./src/modules/MonthlyClose.jsx";
import CashRegister from "./src/modules/CashRegister.jsx";
import CorePrinciples from "./src/modules/CorePrinciples.jsx";
import Handbook from "./src/modules/Handbook.jsx";
import TimeClock from "./src/modules/TimeClock.jsx";
import ErrorBoundary from "./src/components/ErrorBoundary.jsx";
import { supabase, AGENCY_ID } from "./src/lib/supabase.js";
import DemoBanner from "./src/components/DemoBanner.jsx";


// ============================================================
// BCC APP SHELL v1.0
// Business Command Center — State Farm Agent Edition
//
// ARCHITECTURE:
// ┌─────────────────────────────────────────────────────┐
// │  This file: Frontend UI (React)                      │
// │  Data:      Supabase (SUPABASE_URL + ANON_KEY only) │
// │  Execution: Composio (connected accounts)            │
// │  Processing: Groq via Composio (free, no API key)   │
// │  Intelligence: Claude.ai (client's subscription)    │
// │  Hosting:   Vercel (client's free account)          │
// │  Recipes:   Stored in automation_recipes table      │
// │  Schedules: Cron triggers in Supabase               │
// │                                                      │
// │  NO Anthropic API key required in this app.         │
// │  Claude.ai opens in a new tab with context.         │
// └─────────────────────────────────────────────────────┘
//
// AUTH (Path 1 — login gates the UI):
//   The whole app is wrapped in an auth gate. On mount we check for a
//   Supabase session. No session -> Login screen only. Has session ->
//   the full app renders unchanged. Data reads still use anon grants
//   underneath (untouched), so there is no blank-screen risk. Being
//   logged in (authenticated role) is what unlocks writes such as the
//   staff edit form.
//
// ENVIRONMENT VARIABLES NEEDED (.env):
//   VITE_SUPABASE_URL=https://[project].supabase.co
//   VITE_SUPABASE_ANON_KEY=[anon key]
//
// That's it. Two variables. Nothing else.
// ============================================================


// ─── Design Tokens ────────────────────────────────────────────────────────────
// Viewport hook (responsive design)
// Pixel 8 Pro ~412px wide portrait; iPad 10 ~820px portrait; 15" laptop ~1440px+.
// Phone: <640. Tablet: 640-1023. Desktop: >=1024.
function useViewport() {
  const compute = () => {
    if (typeof window === "undefined") return { width: 1024, isPhone: false, isTablet: false, isDesktop: true };
    const w = window.innerWidth;
    return {
      width: w,
      isPhone:   w < 640,
      isTablet:  w >= 640 && w < 1024,
      isDesktop: w >= 1024,
    };
  };
  const [vp, setVp] = useState(compute);
  useEffect(() => {
    const onResize = () => setVp(compute());
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);
  return vp;
}

// paper newt brand palette (applied 2026-06-16) — see brand guidelines for full system.
const TOKENS = {
  // Brand: sage on cream
  sage:      "#737A59",  // primary mark
  sageDeep:  "#6D7453",  // shadow facets
  sageLight: "#7B8260",  // lit facets / hover
  sageTint:  "#EDEFE5",  // sage at low opacity — active-nav background
  olive:     "#4D503F",  // headlines, wordmark
  charcoal:  "#2D2F26",  // long-form body
  cream:     "#FAF7F0",  // primary surface
  warmStone: "#E8E2D1",  // dividers, secondary surfaces

  // Shell semantic keys (repointed — every downstream css ref picks up the new look)
  navy:    "#4D503F",   // header bg → olive
  navyDark:"#3A3D2E",   // header border → deeper olive
  blue:    "#737A59",   // primary accent / active nav / avatar → sage
  blueLt:  "#EDEFE5",   // active-nav background → sage tint

  // Status (unchanged)
  green:   "#10B981",
  greenLt: "#D1FAE5",
  amber:   "#F59E0B",
  amberLt: "#FEF3C7",
  red:     "#EF4444",
  redLt:   "#FEE2E2",

  // Neutrals — slate50 warmed to cream
  slate50: "#FAF7F0",
  slate100:"#F1F5F9",
  slate200:"#E2E8F0",
  slate400:"#94A3B8",
  slate500:"#64748B",
  slate700:"#334155",
  slate900:"#0F172A",
  white:   "#FFFFFF",
};

// Inline header mark — base64 PNG of the reverse (cream) newt icon.
// Embedded so the header is bulletproof even if /public assets ever 404.
const PN_HEADER_ICON_DATA_URL = "data:image/png;base64," + "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";

// ─── App Context ──────────────────────────────────────────────────────────────
const AppContext = createContext(null);
const useApp = () => useContext(AppContext);

// ─── Mock Auth & Agency Data ──────────────────────────────────────────────────
// In production this comes from Supabase Auth + agency table
const MOCK_AGENCY = {
  name: "paper newt management",
  agentCode: "",
  user: { name: "Peter J. Story", initials: "PS", role: "owner", email: "paper.newt.management@gmail.com" },
  alerts: 0,
};

// ─── Navigation Config ────────────────────────────────────────────────────────
const NAV_ITEMS = [
    { id: "dashboard", label: "Dashboard",         icon: "grid",         roles: ["owner","manager","staff","readonly","accountant"] },
  { id: "alerts",    label: "Alerts",            icon: "bell",         roles: ["owner","manager","staff","readonly","accountant"] },
  { id: "tasks",     label: "Tasks",     icon: "check",        roles: ["owner","manager","staff","readonly"] },
  { id: "chat",      label: "Claude",            icon: "message",      roles: ["owner","manager","staff","readonly","accountant"] },
  { id: "financials", label: "Financials",        icon: "dollar",       roles: ["owner","manager","accountant"] },
  { id: "hr",        label: "Team",              icon: "users",        roles: ["owner","manager"] },
  { id: "timeclock", label: "Timeclock",           icon: "clock",        roles: ["owner","manager","staff"] },
  { id: "social",    label: "Social",      icon: "share",        roles: ["owner","manager","staff"] },
  { id: "automations", label: "Automations",       icon: "zap",          roles: ["owner","manager"] },
  { id: "memory",    label: "Memory",            icon: "brain",        roles: ["owner","manager"] },
  { id: "principles", label: "Principles",   icon: "book",         roles: ["owner","manager"] },
  { id: "handbook",  label: "Handbook",          icon: "bookOpen",     roles: ["owner","manager","staff","readonly","accountant"] },
  { id: "settings",  label: "Settings",          icon: "settings",     roles: ["owner"] },
];

// ─── SVG Icons ────────────────────────────────────────────────────────────────
const Icon = ({ name, size = 16, color = "currentColor", strokeWidth = 1.75 }) => {
  const s = { width: size, height: size, flexShrink: 0 };
  const p = { fill: "none", stroke: color, strokeWidth, strokeLinecap: "round", strokeLinejoin: "round" };
  const icons = {
    grid:       <svg style={s} viewBox="0 0 24 24" {...p}><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/></svg>,
    dollar:     <svg style={s} viewBox="0 0 24 24" {...p}><line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/></svg>,
    brain:      <svg style={s} viewBox="0 0 24 24" {...p}><path d="M9.5 2A2.5 2.5 0 0 1 12 4.5v15a2.5 2.5 0 0 1-4.96-.46 2.5 2.5 0 0 1-1.07-4.13A3 3 0 0 1 4 12a3 3 0 0 1 2-2.83 2.5 2.5 0 0 1 1.5-4.17z"/><path d="M14.5 2A2.5 2.5 0 0 0 12 4.5v15a2.5 2.5 0 0 0 4.96-.46 2.5 2.5 0 0 0 1.07-4.13A3 3 0 0 0 20 12a3 3 0 0 0-2-2.83 2.5 2.5 0 0 0-1.5-4.17z"/></svg>,
    shield:     <svg style={s} viewBox="0 0 24 24" {...p}><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><polyline points="9 12 11 14 15 10"/></svg>,
    zap:        <svg style={s} viewBox="0 0 24 24" {...p}><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>,
    share:      <svg style={s} viewBox="0 0 24 24" {...p}><circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.59" y1="13.51" x2="15.42" y2="17.49"/><line x1="15.41" y1="6.51" x2="8.59" y2="10.49"/></svg>,
    check:      <svg style={s} viewBox="0 0 24 24" {...p}><polyline points="9 11 12 14 22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/></svg>,
    bell:       <svg style={s} viewBox="0 0 24 24" {...p}><path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/></svg>,
    folder:     <svg style={s} viewBox="0 0 24 24" {...p}><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>,
    calendar:   <svg style={s} viewBox="0 0 24 24" {...p}><rect x="3" y="4" width="18" height="18" rx="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/></svg>,
    creditCard: <svg style={s} viewBox="0 0 24 24" {...p}><rect x="1" y="4" width="22" height="16" rx="2"/><line x1="1" y1="10" x2="23" y2="10"/></svg>,
    users:      <svg style={s} viewBox="0 0 24 24" {...p}><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>,
    message:    <svg style={s} viewBox="0 0 24 24" {...p}><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>,
    settings:   <svg style={s} viewBox="0 0 24 24" {...p}><circle cx="12" cy="12" r="3"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14M4.93 4.93a10 10 0 0 0 0 14.14"/></svg>,
    chevronLeft:<svg style={s} viewBox="0 0 24 24" {...p}><polyline points="15 18 9 12 15 6"/></svg>,
    chevronRight:<svg style={s} viewBox="0 0 24 24" {...p}><polyline points="9 18 15 12 9 6"/></svg>,
    book:       <svg style={s} viewBox="0 0 24 24" {...p}><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/></svg>,
    bookOpen:   <svg style={s} viewBox="0 0 24 24" {...p}><path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/></svg>,
    clock:      <svg style={s} viewBox="0 0 24 24" {...p}><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>,
    logout:     <svg style={s} viewBox="0 0 24 24" {...p}><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>,
    menu:       <svg style={s} viewBox="0 0 24 24" {...p}><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="18" x2="21" y2="18"/></svg>,
    x:          <svg style={s} viewBox="0 0 24 24" {...p}><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>,
    lightning:  <svg style={s} viewBox="0 0 24 24" fill={color} stroke="none"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>,
    externalLink:<svg style={s} viewBox="0 0 24 24" {...p}><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>,
  };
  return icons[name] || null;
};

// ─── Styles (CSS-in-JS) ───────────────────────────────────────────────────────
const css = {
  app: {
    display: "flex", flexDirection: "column",
    height: "100vh", minHeight: 600,
    fontFamily: "'Poppins', 'Helvetica Neue', sans-serif",
    background: TOKENS.slate50,
    overflow: "hidden",
  },

  // Header
  header: {
    background: TOKENS.navy,
    height: 58,
    display: "flex", alignItems: "center",
    justifyContent: "space-between",
    padding: "0 20px",
    flexShrink: 0,
    borderBottom: `1px solid ${TOKENS.navyDark}`,
    zIndex: 100,
  },
  headerLeft: { display: "flex", alignItems: "center", gap: 12 },
  headerLogo: {
    width: 32, height: 32,
    background: TOKENS.blue,
    borderRadius: 8,
    display: "flex", alignItems: "center", justifyContent: "center",
  },
  agencyName: { fontSize: 14, fontWeight: 600, color: TOKENS.white, letterSpacing: "-0.01em" },
  agencySub:  { fontSize: 10, color: TOKENS.slate400, marginTop: 1 },
  headerRight: { display: "flex", alignItems: "center", gap: 16 },
  bellWrap: { position: "relative", cursor: "pointer", padding: 4 },
  bellBadge: {
    position: "absolute", top: 0, right: 0,
    background: TOKENS.red, color: TOKENS.white,
    fontSize: 9, fontWeight: 700,
    borderRadius: "50%", width: 16, height: 16,
    display: "flex", alignItems: "center", justifyContent: "center",
    border: `2px solid ${TOKENS.navy}`,
  },
  userPill: {
    display: "flex", alignItems: "center", gap: 8,
    cursor: "pointer", padding: "4px 8px",
    borderRadius: 8,
    transition: "background 0.15s",
  },
  avatar: {
    width: 30, height: 30, borderRadius: "50%",
    background: TOKENS.blue,
    display: "flex", alignItems: "center", justifyContent: "center",
    fontSize: 11, fontWeight: 700, color: TOKENS.white,
    flexShrink: 0,
  },
  userName: { fontSize: 12, fontWeight: 600, color: TOKENS.white },
  userRole: { fontSize: 10, color: TOKENS.slate400, textTransform: "capitalize" },

  // Body
  body: { display: "flex", flex: 1, overflow: "hidden" },

  // Sidebar Nav
  nav: (collapsed) => ({
    width: collapsed ? 56 : 220,
    background: TOKENS.white,
    borderRight: `1px solid ${TOKENS.slate200}`,
    display: "flex", flexDirection: "column",
    flexShrink: 0,
    transition: "width 0.2s ease",
    overflow: "hidden",
    zIndex: 50,
  }),
  navScroll: { flex: 1, overflowY: "auto", overflowX: "hidden", padding: "8px 0" },
  navItem: (active, collapsed) => ({
    display: "flex", alignItems: "center",
    gap: collapsed ? 0 : 10,
    padding: collapsed ? "10px 0" : "9px 14px",
    justifyContent: collapsed ? "center" : "flex-start",
    cursor: "pointer",
    fontSize: 12.5, fontWeight: active ? 600 : 400,
    color: active ? TOKENS.blue : TOKENS.slate500,
    background: active ? TOKENS.blueLt : "transparent",
    borderLeft: active ? `3px solid ${TOKENS.blue}` : "3px solid transparent",
    borderRadius: collapsed ? 0 : "0 6px 6px 0",
    marginRight: collapsed ? 0 : 8,
    transition: "all 0.12s",
    whiteSpace: "nowrap",
    overflow: "hidden",
  }),
  navLabel: (collapsed) => ({
    opacity: collapsed ? 0 : 1,
    maxWidth: collapsed ? 0 : 160,
    transition: "opacity 0.15s, max-width 0.2s",
    overflow: "hidden",
  }),
  navCollapseBtn: {
    padding: "10px 0",
    display: "flex", alignItems: "center", justifyContent: "center",
    borderTop: `1px solid ${TOKENS.slate200}`,
    cursor: "pointer",
    color: TOKENS.slate400,
    transition: "color 0.15s",
  },
  navFooter: {
    padding: "8px 14px 12px",
    borderTop: `1px solid ${TOKENS.slate200}`,
  },

  // Main Content
  main: {
    flex: 1, overflowY: "auto",
    display: "flex", flexDirection: "column",
  },
  mainInner: { flex: 1, padding: "20px 24px" },

  // Page Header (used by each module)
  pageHeader: {
    display: "flex", alignItems: "flex-start",
    justifyContent: "space-between",
    marginBottom: 20,
  },
  pageTitle: {
    fontSize: 20, fontWeight: 700,
    color: TOKENS.slate900, letterSpacing: "-0.02em",
  },
  pageSubtitle: {
    fontSize: 12, color: TOKENS.slate500, marginTop: 3,
  },

  // Ask Claude Button
  askBtn: {
    display: "flex", alignItems: "center", gap: 6,
    background: TOKENS.blue, color: TOKENS.white,
    border: "none", borderRadius: 8,
    padding: "8px 14px",
    fontSize: 12, fontWeight: 600,
    cursor: "pointer",
    transition: "background 0.15s, transform 0.1s",
    whiteSpace: "nowrap",
    flexShrink: 0,
  },

  // Cards
  card: {
    background: TOKENS.white,
    border: `1px solid ${TOKENS.slate200}`,
    borderRadius: 12,
    padding: "16px 18px",
  },
  cardTitle: {
    fontSize: 12, fontWeight: 600,
    color: TOKENS.slate700,
    marginBottom: 12,
    display: "flex", alignItems: "center",
    justifyContent: "space-between",
  },

  // KPI Cards
  kpiGrid: {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))",
    gap: 12, marginBottom: 16,
  },
  kpi: {
    background: TOKENS.white,
    border: `1px solid ${TOKENS.slate200}`,
    borderRadius: 12, padding: "14px 16px",
  },
  kpiLabel: { fontSize: 11, color: TOKENS.slate500, marginBottom: 6, fontWeight: 500 },
  kpiValue: { fontSize: 22, fontWeight: 700, color: TOKENS.slate900, letterSpacing: "-0.02em", marginBottom: 4 },
  kpiTrend: { fontSize: 11, display: "flex", alignItems: "center", gap: 4 },

  // Status Pills
  pill: (type) => {
    const map = {
      success: { bg: TOKENS.greenLt, color: "#065F46" },
      warning: { bg: TOKENS.amberLt, color: "#92400E" },
      danger:  { bg: TOKENS.redLt,   color: "#991B1B" },
      info:    { bg: TOKENS.blueLt,  color: "#1E40AF" },
    };
    const t = map[type] || map.info;
    return {
      display: "inline-flex", alignItems: "center",
      fontSize: 10, fontWeight: 600,
      padding: "3px 8px", borderRadius: 20,
      background: t.bg, color: t.color,
      whiteSpace: "nowrap",
    };
  },

  // Footer
  footer: {
    padding: "8px 24px",
    borderTop: `1px solid ${TOKENS.slate200}`,
    background: TOKENS.white,
    textAlign: "center",
    fontSize: 10, color: TOKENS.slate400,
    flexShrink: 0,
  },
};

// ─── Ask Claude Button Component ──────────────────────────────────────────────
const AskClaudeBtn = ({ context, size = "normal" }) => {
  const handleClick = () => {
    const prompt = context || "I am reviewing my Business Command Center. Help me analyze what I'm seeing.";
    navigator.clipboard?.writeText(prompt).catch(() => {});
    window.open("https://claude.ai", "_blank");
  };
  return (
    <button
      style={{
        ...css.askBtn,
        padding: size === "small" ? "5px 10px" : "8px 14px",
        fontSize: size === "small" ? 11 : 12,
      }}
      onClick={handleClick}
      title="Copies context to clipboard and opens Claude.ai"
    >
      <Icon name="lightning" size={12} color={TOKENS.white} />
      Ask Claude
      <Icon name="externalLink" size={11} color="rgba(255,255,255,0.7)" />
    </button>
  );
};

// ─── Login Screen ─────────────────────────────────────────────────────────────
// Path 1 auth: this gates the UI. The data layer (anon reads) is untouched,
// so there is no blank-screen risk. Signing in (authenticated role) is what
// unlocks writes such as the staff edit form.
const LoginScreen = ({ onSignedIn }) => {
  const [email, setEmail]       = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy]         = useState(false);
  const [error, setError]       = useState("");

  const submit = async (e) => {
    if (e && e.preventDefault) e.preventDefault();
    if (busy) return;
    setError("");
    const em = email.trim();
    if (!em || !password) { setError("Enter your email and password."); return; }
    if (!supabase) { setError("Auth is not configured. Check Supabase connection."); return; }
    setBusy(true);
    try {
      const { data, error: signInErr } = await supabase.auth.signInWithPassword({
        email: em,
        password,
      });
      if (signInErr) {
        setError(signInErr.message || "Sign in failed. Check your email and password.");
        setBusy(false);
        return;
      }
      if (data?.session) {
        if (onSignedIn) onSignedIn(data.session);
      } else {
        setError("Sign in did not return a session. Try again.");
        setBusy(false);
      }
    } catch (err) {
      setError(err?.message || "Unexpected error during sign in.");
      setBusy(false);
    }
  };

  return (
    <div style={{
      minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center",
      background: TOKENS.navy, fontFamily: "'Poppins', 'Helvetica Neue', sans-serif", padding: 20,
    }}>
      <div style={{
        width: "100%", maxWidth: 380, background: TOKENS.white,
        borderRadius: 16, padding: "32px 30px",
        boxShadow: "0 12px 40px rgba(0,0,0,0.25)",
      }}>
        {/* Logo + heading */}
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", marginBottom: 24 }}>
          <div style={{ width: 44, height: 44, background: TOKENS.blue, borderRadius: 12, display: "flex", alignItems: "center", justifyContent: "center", marginBottom: 14 }}>
            <img src={PN_HEADER_ICON_DATA_URL} alt="paper newt" width={28} height={28} style={{ display: "block" }} />
          </div>
          <div style={{ fontSize: 18, fontWeight: 700, color: TOKENS.slate900, letterSpacing: "-0.02em" }}>Business Command Center</div>
          <div style={{ fontSize: 12, color: TOKENS.slate500, marginTop: 4 }}>Sign in to continue</div>
        </div>

        <form onSubmit={submit}>
          <label style={{ display: "block", fontSize: 11, fontWeight: 600, color: TOKENS.slate700, marginBottom: 5 }}>Email</label>
          <input
            type="email" value={email} onChange={(e) => setEmail(e.target.value)}
            autoComplete="username" placeholder="you@example.com"
            style={{ width: "100%", boxSizing: "border-box", padding: "10px 12px", fontSize: 13, color: TOKENS.slate900, border: `1px solid ${TOKENS.slate200}`, borderRadius: 8, outline: "none", marginBottom: 14, background: TOKENS.white }}
          />

          <label style={{ display: "block", fontSize: 11, fontWeight: 600, color: TOKENS.slate700, marginBottom: 5 }}>Password</label>
          <input
            type="password" value={password} onChange={(e) => setPassword(e.target.value)}
            autoComplete="current-password" placeholder="••••••••"
            style={{ width: "100%", boxSizing: "border-box", padding: "10px 12px", fontSize: 13, color: TOKENS.slate900, border: `1px solid ${TOKENS.slate200}`, borderRadius: 8, outline: "none", marginBottom: 16, background: TOKENS.white }}
          />

          {error && (
            <div style={{ fontSize: 12, color: "#991B1B", background: TOKENS.redLt, border: `1px solid #FECACA`, borderRadius: 8, padding: "8px 10px", marginBottom: 14, lineHeight: 1.5 }}>
              {error}
            </div>
          )}

          <button
            type="submit" disabled={busy}
            style={{ width: "100%", padding: "11px", fontSize: 13, fontWeight: 700, color: TOKENS.white, background: busy ? TOKENS.slate400 : TOKENS.blue, border: "none", borderRadius: 10, cursor: busy ? "not-allowed" : "pointer", transition: "background 0.15s" }}
          >
            {busy ? "Signing in…" : "Sign In"}
          </button>
        </form>

        <div style={{ fontSize: 10, color: TOKENS.slate400, textAlign: "center", marginTop: 18, lineHeight: 1.6 }}>
          Accounts are created by your administrator.<br />Contact your agency owner for access.
        </div>
      </div>
    </div>
  );
};

// ─── Set Password Screen (invite / recovery deep links) ──────────────────────
// When a teammate clicks the invite or password-reset email, Supabase puts a
// session in the URL hash and fires onAuthStateChange. We show this screen so
// they can set their password, then drop them into the app.
const SetPasswordScreen = ({ email, onDone }) => {
  const [pw, setPw]   = useState("");
  const [pw2, setPw2] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const submit = async (e) => {
    if (e && e.preventDefault) e.preventDefault();
    if (busy) return;
    setError("");
    if (pw.length < 8) { setError("Password must be at least 8 characters."); return; }
    if (pw !== pw2) { setError("Passwords don't match."); return; }
    if (!supabase) { setError("Auth is not configured."); return; }
    setBusy(true);
    try {
      const { error: updErr } = await supabase.auth.updateUser({ password: pw });
      if (updErr) { setError(updErr.message || "Could not set password."); setBusy(false); return; }
      // Mark the profile active now that they've completed setup.
      try {
        const { data: who } = await supabase.auth.getUser();
        if (who?.user?.id) {
          await supabase.from("users")
            .update({ invite_status: "active", last_login: new Date().toISOString() })
            .eq("auth_user_id", who.user.id);
        }
      } catch (_) { /* non-fatal */ }
      // Clear the hash tokens from the URL and enter the app.
      try { window.history.replaceState(null, "", window.location.pathname); } catch (_) {}
      if (onDone) onDone();
    } catch (err) {
      setError(err?.message || "Unexpected error.");
      setBusy(false);
    }
  };

  return (
    <div style={{ minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center", background: TOKENS.navy, fontFamily: "'Poppins', 'Helvetica Neue', sans-serif", padding: 20 }}>
      <div style={{ width: "100%", maxWidth: 380, background: TOKENS.white, borderRadius: 16, padding: "32px 30px", boxShadow: "0 12px 40px rgba(0,0,0,0.25)" }}>
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", marginBottom: 24 }}>
          <div style={{ width: 44, height: 44, background: TOKENS.blue, borderRadius: 12, display: "flex", alignItems: "center", justifyContent: "center", marginBottom: 14 }}>
            <img src={PN_HEADER_ICON_DATA_URL} alt="paper newt" width={28} height={28} style={{ display: "block" }} />
          </div>
          <div style={{ fontSize: 18, fontWeight: 700, color: TOKENS.slate900, letterSpacing: "-0.02em" }}>Welcome to your BCC</div>
          <div style={{ fontSize: 12, color: TOKENS.slate500, marginTop: 4, textAlign: "center" }}>
            {email ? <>Set a password for <strong>{email}</strong></> : "Set a password to finish setting up your account"}
          </div>
        </div>
        <form onSubmit={submit}>
          <label style={{ display: "block", fontSize: 11, fontWeight: 600, color: TOKENS.slate700, marginBottom: 5 }}>New Password</label>
          <input type="password" value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="new-password" placeholder="At least 8 characters"
            style={{ width: "100%", boxSizing: "border-box", padding: "10px 12px", fontSize: 13, color: TOKENS.slate900, border: `1px solid ${TOKENS.slate200}`, borderRadius: 8, outline: "none", marginBottom: 14, background: TOKENS.white }} />
          <label style={{ display: "block", fontSize: 11, fontWeight: 600, color: TOKENS.slate700, marginBottom: 5 }}>Confirm Password</label>
          <input type="password" value={pw2} onChange={(e) => setPw2(e.target.value)} autoComplete="new-password" placeholder="••••••••"
            style={{ width: "100%", boxSizing: "border-box", padding: "10px 12px", fontSize: 13, color: TOKENS.slate900, border: `1px solid ${TOKENS.slate200}`, borderRadius: 8, outline: "none", marginBottom: 16, background: TOKENS.white }} />
          {error && (
            <div style={{ fontSize: 12, color: "#991B1B", background: TOKENS.redLt, border: `1px solid #FECACA`, borderRadius: 8, padding: "8px 10px", marginBottom: 14, lineHeight: 1.5 }}>{error}</div>
          )}
          <button type="submit" disabled={busy}
            style={{ width: "100%", padding: "11px", fontSize: 13, fontWeight: 700, color: TOKENS.white, background: busy ? TOKENS.slate400 : TOKENS.blue, border: "none", borderRadius: 10, cursor: busy ? "not-allowed" : "pointer" }}>
            {busy ? "Saving…" : "Set Password & Continue"}
          </button>
        </form>
      </div>
    </div>
  );
};

// ─── Module Placeholders ──────────────────────────────────────────────────────
// Each will be replaced with full module builds in subsequent steps

const ComingSoon = ({ module }) => (
  <div style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", flex: 1, gap: 12, padding: 40, textAlign: "center" }}>
    <div style={{ width: 56, height: 56, borderRadius: 16, background: TOKENS.blueLt, display: "flex", alignItems: "center", justifyContent: "center" }}>
      <Icon name="zap" size={24} color={TOKENS.blue} />
    </div>
    <div style={{ fontSize: 18, fontWeight: 700, color: TOKENS.slate900 }}>{module}</div>
    <div style={{ fontSize: 13, color: TOKENS.slate500, maxWidth: 300, lineHeight: 1.6 }}>
      This module is being built. Check back as we complete each section of your BCC.
    </div>
  </div>
);

// ─── Module Router ────────────────────────────────────────────────────────────
// All 11 modules built. In production each is imported from src/modules/.
// This shell routes to each module component. ComingSoon is only used
// for the Claude module which connects to Claude.ai externally.
const ModuleRouter = ({ active, onNavigate }) => {
  const modules = {
    dashboard:   <ErrorBoundary name="Dashboard"><Dashboard onNavigate={onNavigate} /></ErrorBoundary>,
    financials:  <ErrorBoundary name="Financials"><Financials /></ErrorBoundary>,
    principles:  <ErrorBoundary name="Core Principles"><CorePrinciples /></ErrorBoundary>,
    handbook:    <ErrorBoundary name="Handbook"><Handbook /></ErrorBoundary>,
    memory:      <ErrorBoundary name="Memory"><PersistentMemory /></ErrorBoundary>,
    automations: <ErrorBoundary name="Automations"><Automations /></ErrorBoundary>,
    social:      <ErrorBoundary name="Social Media"><SocialMedia /></ErrorBoundary>,
    tasks:       <ErrorBoundary name="Tasks & Goals"><TasksGoals /></ErrorBoundary>,
    alerts:      <ErrorBoundary name="Alerts"><AlertsNotifications onNavigate={onNavigate} /></ErrorBoundary>,
    hr:          <ErrorBoundary name="HR & People"><HRPeople /></ErrorBoundary>,
    timeclock:   <ErrorBoundary name="Timeclock"><TimeClock /></ErrorBoundary>,
    settings:    <ErrorBoundary name="Settings"><Settings /></ErrorBoundary>,
    chat: (
      <div style={{ display:"flex", flexDirection:"column", alignItems:"center", justifyContent:"center", flex:1, gap:16, padding:40, textAlign:"center" }}>
        <div style={{ fontSize:40 }}>ð¬</div>
        <div style={{ fontSize:18, fontWeight:700, color:TOKENS.slate900 }}>Claude</div>
        <div style={{ fontSize:13, color:TOKENS.slate500, maxWidth:360, lineHeight:1.7 }}>
          Your Claude.ai account is your intelligence layer. Open it in a new tab and your BCC data is already in context through your Project instructions.
        </div>
        <button
          onClick={() => window.open("https://claude.ai","_blank")}
          style={{ display:"flex", alignItems:"center", gap:8, background:TOKENS.blue, color:"#fff", border:"none", borderRadius:10, padding:"12px 24px", fontSize:13, fontWeight:700, cursor:"pointer" }}
        >
          <Icon name="externalLink" size={14} color="#fff" />
          Open Claude.ai
        </button>
        <div style={{ fontSize:11, color:TOKENS.slate400, maxWidth:320, lineHeight:1.6 }}>
          Tip: Use the Ask Claude buttons throughout your BCC — they open Claude.ai with your data already in the prompt. One paste and Claude knows exactly what you're looking at.
        </div>
      </div>
    ),
  };
  return modules[active] || <ComingSoon module={active} />;
};

// ─── Main App ─────────────────────────────────────────────────────────────────
export default function BCCApp() {
  // ── Auth gate state (Path 1) ──────────────────────────────────────────────
  // authState: "checking" | "out" | "in"
  const [authState, setAuthState] = useState("checking");
  const [sessionEmail, setSessionEmail] = useState("");
  // When arriving via an invite or password-reset link, force a set-password step.
  const [needsPassword, setNeedsPassword] = useState(() => {
    if (typeof window === "undefined") return false;
    const h = window.location.hash || "";
    return /type=(invite|recovery|signup)/.test(h);
  });

  const [activeModule, setActiveModule] = useState("dashboard");
  const viewport = useViewport();
  // Sidebar starts collapsed on phone/tablet (manual toggle still works thereafter).
  const [navCollapsed, setNavCollapsed] = useState(() => {
    if (typeof window === "undefined") return false;
    return window.innerWidth < 1024;
  });
  const [userMenuOpen, setUserMenuOpen] = useState(false);
  const [agency, setAgency] = useState(MOCK_AGENCY);

  // Check for an existing session on mount, and subscribe to auth changes.
  useEffect(() => {
    let mounted = true;
    if (!supabase) {
      // No client at all — fail open to the app (data still reads via anon),
      // rather than locking the user out of a misconfigured build.
      setAuthState("in");
      return;
    }
    supabase.auth.getSession().then(({ data }) => {
      if (!mounted) return;
      const session = data?.session || null;
      setSessionEmail(session?.user?.email || "");
      setAuthState(session ? "in" : "out");
    }).catch(() => {
      if (mounted) setAuthState("out");
    });

    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      if (!mounted) return;
      setSessionEmail(session?.user?.email || "");
      // Supabase fires PASSWORD_RECOVERY for recovery links; invite links land
      // as a normal signed-in session but with type=invite in the URL hash.
      if (event === "PASSWORD_RECOVERY") setNeedsPassword(true);
      const hash = (typeof window !== "undefined" && window.location.hash) || "";
      if (/type=(invite|recovery|signup)/.test(hash)) setNeedsPassword(true);
      setAuthState(session ? "in" : "out");
    });

    return () => {
      mounted = false;
      sub?.subscription?.unsubscribe?.();
    };
  }, []);

  // allowed_modules for the logged-in user. null = all modules (owner/manager
  // default). An array means "only these module ids are visible".
  const [allowedModules, setAllowedModules] = useState(null);

  // Load real agency + the logged-in user's BCC profile once past the auth gate.
  useEffect(() => {
    if (authState !== "in") return;
    if (!supabase || !AGENCY_ID) return;

    async function loadProfile() {
      // Agency basics
      const { data: ag } = await supabase
        .from("agency")
        .select("name, state_farm_agent_code, owner_name, primary_email")
        .eq("id", AGENCY_ID)
        .single();

      // The signed-in user's own row — drives role + module visibility.
      // Match on email (case-insensitive) since that's what auth gives us.
      let profile = null;
      const email = (sessionEmail || "").toLowerCase();
      if (email) {
        const { data: rows } = await supabase
          .from("users")
          .select("full_name, role, allowed_modules, email")
          .eq("agency_id", AGENCY_ID)
          .ilike("email", email)
          .limit(1);
        profile = (rows && rows[0]) || null;
      }

      const role = profile?.role || "owner"; // fallback: treat unknown as owner
      // allowed_modules: null/empty for owner & manager = full access.
      const mods = (role === "owner" || role === "manager")
        ? null
        : (Array.isArray(profile?.allowed_modules) && profile.allowed_modules.length > 0
            ? profile.allowed_modules
            : null);
      setAllowedModules(mods);

      const displayName = profile?.full_name || ag?.owner_name || MOCK_AGENCY.user.name;
      setAgency({
        name: ag?.name || MOCK_AGENCY.name,
        agentCode: ag?.state_farm_agent_code || MOCK_AGENCY.agentCode,
        user: {
          name: displayName,
          initials: (displayName || "?").split(" ").map(n => n?.[0] || "").join("").toUpperCase().slice(0,2),
          role,
          email: profile?.email || ag?.primary_email || sessionEmail || MOCK_AGENCY.user.email,
        },
        alerts: MOCK_AGENCY.alerts,
      });
    }

    loadProfile().catch(e => console.error("[BCCApp] profile load error:", e));
  }, [authState, sessionEmail]);

  const handleSignOut = async () => {
    setUserMenuOpen(false);
    try {
      if (supabase) await supabase.auth.signOut();
    } catch (e) {
      // ignore — onAuthStateChange will still flip us to "out"
    }
    setAuthState("out");
  };

  // ── Auth gate render ───────────────────────────────────────────────────────
  if (authState === "checking") {
    return (
      <div style={{ minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center", background: TOKENS.slate50, fontFamily: "'Poppins', 'Helvetica Neue', sans-serif", fontSize: 13, color: TOKENS.slate500 }}>
        Loading…
      </div>
    );
  }
  if (authState === "out") {
    return <LoginScreen onSignedIn={() => setAuthState("in")} />;
  }
  // Invite / recovery deep link: make them set a password before entering.
  if (needsPassword) {
    return <SetPasswordScreen email={sessionEmail} onDone={() => { setNeedsPassword(false); setAuthState("in"); }} />;
  }

  // ── Authenticated app (unchanged below) ────────────────────────────────────
  const visibleNav = NAV_ITEMS.filter(n => {
    if (!n.roles.includes(agency.user.role)) return false;
    // If allowed_modules is set (non-owner/manager with explicit module list),
    // only show those modules. Settings always restricted to owner via roles.
    if (Array.isArray(allowedModules)) return allowedModules.includes(n.id);
    return true;
  });

  return (
    <AppContext.Provider value={{ agency, activeModule, setActiveModule }}>
      <div style={css.app}>
        <DemoBanner />

        {/* ── Header ── */}
        <header style={{ ...css.header, padding: viewport.isPhone ? "0 10px" : "0 20px" }}>
          <div style={css.headerLeft}>
            <div style={css.headerLogo}>
              <img src={PN_HEADER_ICON_DATA_URL} alt="paper newt" width={22} height={22} style={{ display: "block" }} />
            </div>
            <div>
              <div style={css.agencyName}>{agency.name}</div>
              <div style={css.agencySub}>Business Command Center</div>
            </div>
          </div>

          <div style={css.headerRight}>
            {/* Alerts Bell */}
            <div style={css.bellWrap} title={`${agency.alerts} active alerts`}>
              <Icon name="bell" size={18} color={TOKENS.slate400} />
              {agency.alerts > 0 && <span style={css.bellBadge}>{agency.alerts}</span>}
            </div>

            {/* User Menu */}
            <div style={{ position: "relative" }}>
              <div
                style={css.userPill}
                onClick={() => setUserMenuOpen(o => !o)}
              >
                <div style={css.avatar}>{agency.user.initials}</div>
                <div>
                  <div style={css.userName}>{agency.user.name}</div>
                  <div style={css.userRole}>{agency.user.role}</div>
                </div>
              </div>
              {userMenuOpen && (
                <div style={{
                  position: "absolute", right: 0, top: "calc(100% + 8px)",
                  background: TOKENS.white, border: `1px solid ${TOKENS.slate200}`,
                  borderRadius: 10, padding: 6, minWidth: 160,
                  boxShadow: "0 4px 16px rgba(0,0,0,0.12)", zIndex: 200,
                }}>
                  <div style={{ padding: "8px 10px", fontSize: 11, color: TOKENS.slate500, borderBottom: `1px solid ${TOKENS.slate200}`, marginBottom: 4 }}>
                    {sessionEmail || agency.user.email}
                  </div>
                  {["Profile", "Notification Settings", "Team Access"].map(item => (
                    <div key={item} style={{ padding: "7px 10px", fontSize: 12, color: TOKENS.slate700, cursor: "pointer", borderRadius: 6 }}
                      onClick={() => { setActiveModule("settings"); setUserMenuOpen(false); }}>
                      {item}
                    </div>
                  ))}
                  <div style={{ borderTop: `1px solid ${TOKENS.slate200}`, marginTop: 4, paddingTop: 4 }}>
                    <div
                      style={{ padding: "7px 10px", fontSize: 12, color: TOKENS.red, cursor: "pointer", borderRadius: 6, display: "flex", alignItems: "center", gap: 8 }}
                      onClick={handleSignOut}
                    >
                      <Icon name="logout" size={13} color={TOKENS.red} /> Sign out
                    </div>
                  </div>
                </div>
              )}
            </div>
          </div>
        </header>

        {/* ── Body ── */}
        <div style={css.body} onClick={() => userMenuOpen && setUserMenuOpen(false)}>

          {/* ── Sidebar ── */}
          <nav style={css.nav(navCollapsed)}>
            <div style={css.navScroll}>
              {visibleNav.map(item => {
                const active = activeModule === item.id;
                return (
                  <div
                    key={item.id}
                    style={css.navItem(active, navCollapsed)}
                    onClick={() => setActiveModule(item.id)}
                    title={navCollapsed ? item.label : ""}
                  >
                    <Icon
                      name={item.icon}
                      size={15}
                      color={active ? TOKENS.blue : TOKENS.slate400}
                    />
                    <span style={css.navLabel(navCollapsed)}>{item.label}</span>
                    {item.id === "alerts" && !navCollapsed && agency.alerts > 0 && (
                      <span style={{ ...css.pill("danger"), marginLeft: "auto", fontSize: 9, padding: "2px 6px" }}>
                        {agency.alerts}
                      </span>
                    )}
                  </div>
                );
              })}
            </div>

            {/* Collapse Toggle */}
            <div
              style={css.navCollapseBtn}
              onClick={() => setNavCollapsed(c => !c)}
              title={navCollapsed ? "Expand navigation" : "Collapse navigation"}
            >
              <Icon name={navCollapsed ? "chevronRight" : "chevronLeft"} size={14} color={TOKENS.slate400} />
            </div>
          </nav>

          {/* ── Main Content ── */}
          <main style={css.main}>
            <div style={{ ...css.mainInner, padding: viewport.isPhone ? "12px 12px" : viewport.isTablet ? "16px 18px" : "20px 24px" }}>
              <ModuleRouter active={activeModule} onNavigate={setActiveModule} />
            </div>

            {/* Footer */}
            <div style={css.footer}>
              {agency.name} &nbsp;·&nbsp; Business Command Center
            </div>
          </main>
        </div>
      </div>
    </AppContext.Provider>
  );
}
