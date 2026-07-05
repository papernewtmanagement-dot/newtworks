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
import Playbook from "./src/modules/Playbook.jsx";
import Admin from "./src/modules/Admin.jsx";
import TimeHub from "./src/modules/TimeHub.jsx";
import CPRDetail from "./src/modules/CPRDetail.jsx";
import CPRList from "./src/modules/CPRList.jsx";
import Renewals from "./src/modules/Renewals.jsx";
import FitScorecards from "./src/modules/FitScorecards.jsx";
import ErrorBoundary from "./src/components/ErrorBoundary.jsx";
import AgencyIdentityRibbon from "./src/components/AgencyIdentityRibbon.jsx";
import { supabase, AGENCY_ID } from "./src/lib/supabase.js";
import { useViewport } from "./src/lib/hooks.js";
import DemoBanner from "./src/components/DemoBanner.jsx";

import { TOKENS } from "./src/lib/theme.js";


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
// │  Hosting:   Vercel (client's account)               │
// │  Recipes:   Stored in automation_recipes table      │
// │  Schedules: Cron triggers in Supabase               │
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
// useViewport now lives in src/lib/hooks.js — imported above and used by modules too.

// ─── App Context ──────────────────────────────────────────────────────────────
const AppContext = createContext(null);
const useApp = () => useContext(AppContext);

// ─── Default Agency Identity (fallback if DB read fails) ──────────────────────
// Live values come from Supabase Auth + the agency table. These defaults only
// render if the agency fetch errors out (network blip, RLS misconfig, etc.).
const AGENCY_DEFAULTS = {
  name: "Paper Newt Management LLC",
  agentCode: "TX-2277768",
  user: { id: null, name: "Peter Story", initials: "PS", role: "owner", email: "paper.newt.management@gmail.com" },
  alerts: 0,
};

// ─── Navigation Config ────────────────────────────────────────────────────────
// ─── Access model ─────────────────────────────────────────────────────────────
// admin tier = ["owner","manager"] — full access to every module.
// team tier  = anyone else (staff/readonly/accountant) — sees ONLY the 5
//              team-visible sections (dashboard, cpr, time, handbook, playbook).
// Standing rule (Peter 2026-06-22): webapp defaults to admin-only. Any NEW
// module added below MUST default to roles: ADMIN_ROLES unless Peter explicitly
// authorizes team visibility. See persistent_memory operational_rule
// "BCC webapp default visibility — owner-only unless Peter authorizes team access".
const ADMIN_ROLES = ["owner", "manager"];
const TEAM_VISIBLE_ROLES = ["owner", "manager", "staff", "readonly", "accountant"];
const NAV_ITEMS = [
  { id: "dashboard",   label: "Dashboard",   icon: "grid",          roles: TEAM_VISIBLE_ROLES },
  { type: "divider",   id: "_div_team_top" },
  { id: "cpr",         label: "CPR",         icon: "trendingUp",    roles: TEAM_VISIBLE_ROLES },
  { id: "time",        label: "Hours",       icon: "clock",         roles: TEAM_VISIBLE_ROLES },
  { id: "handbook",    label: "Handbook",    icon: "bookOpen",      roles: TEAM_VISIBLE_ROLES },
  { id: "playbook",    label: "Processes",   icon: "clipboardList", roles: TEAM_VISIBLE_ROLES },
  { id: "renewals",    label: "Renewals",    icon: "shield",        roles: TEAM_VISIBLE_ROLES },
  { id: "scorecards",  label: "Scorecards",  icon: "check",         roles: TEAM_VISIBLE_ROLES },
  { type: "divider",   id: "_div_admin_top" },
  { id: "alerts",      label: "Alerts",      icon: "bell",          roles: ADMIN_ROLES },
  { id: "tasks",       label: "Tasks",       icon: "check",         roles: ADMIN_ROLES },
  { id: "financials",  label: "Financials",  icon: "dollar",        roles: ADMIN_ROLES },
  { id: "hr",          label: "Team",        icon: "users",         roles: ADMIN_ROLES },
  { id: "social",      label: "Social",      icon: "share",         roles: ADMIN_ROLES },
  { type: "divider",   id: "_div_admin_bot" },
  { id: "automations", label: "Automations", icon: "zap",           roles: ADMIN_ROLES },
  { id: "memory",      label: "Memory",      icon: "brain",         roles: ADMIN_ROLES },
  { id: "principles",  label: "Principles",  icon: "book",          roles: ADMIN_ROLES },
  { id: "admin",       label: "Admin",       icon: "briefcase",     roles: ADMIN_ROLES },
  { id: "settings",    label: "Settings",    icon: "settings",      roles: ADMIN_ROLES },
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
    calendarOff:<svg style={s} viewBox="0 0 24 24" {...p}><path d="M4.2 4.2A2 2 0 0 0 3 6v14a2 2 0 0 0 2 2h14a2 2 0 0 0 1.8-1.2"/><path d="M21 15.5V6a2 2 0 0 0-2-2H9.5"/><line x1="3" y1="10" x2="14" y2="10"/><path d="M16 2v4"/><path d="M8 2v2"/><line x1="2" y1="2" x2="22" y2="22"/></svg>,
    trendingUp:<svg style={s} viewBox="0 0 24 24" {...p}><polyline points="22 7 13.5 15.5 8.5 10.5 2 17"/><polyline points="16 7 22 7 22 13"/></svg>,
    clipboardList:<svg style={s} viewBox="0 0 24 24" {...p}><rect x="8" y="2" width="8" height="4" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M12 11h4"/><path d="M12 16h4"/><path d="M8 11h.01"/><path d="M8 16h.01"/></svg>,
    briefcase:<svg style={s} viewBox="0 0 24 24" {...p}><rect x="2" y="7" width="20" height="14" rx="2" ry="2"/><path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/></svg>,
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
    background: TOKENS.chromeBg,
    height: 58,
    display: "flex", alignItems: "center",
    justifyContent: "space-between",
    padding: "0 20px",
    flexShrink: 0,
    borderBottom: `1px solid ${TOKENS.chromeBorder}`,
    zIndex: 100,
  },
  headerLeft: { display: "flex", alignItems: "center", gap: 12 },
  headerLogo: {
    display: "flex", alignItems: "center",
    flexShrink: 0,
  },
  agencyName: { fontFamily: '"Quicksand", "Poppins", sans-serif', fontSize: 22, fontWeight: 500, color: TOKENS.chromeText, letterSpacing: "0.04em" },
  headerRight: { display: "flex", alignItems: "center", gap: 16 },
  bellWrap: { position: "relative", cursor: "pointer", padding: 4 },
  bellBadge: {
    position: "absolute", top: 0, right: 0,
    background: TOKENS.red, color: TOKENS.white,
    fontSize: 9, fontWeight: 700,
    borderRadius: "50%", width: 16, height: 16,
    display: "flex", alignItems: "center", justifyContent: "center",
    border: `2px solid ${TOKENS.chromeBg}`,
  },
  userPill: {
    display: "flex", alignItems: "center", gap: 8,
    cursor: "pointer", padding: "4px 8px",
    borderRadius: 8,
    transition: "background 0.15s",
  },
  avatar: {
    width: 30, height: 30, borderRadius: "50%",
    background: TOKENS.chromeBgDeep,
    display: "flex", alignItems: "center", justifyContent: "center",
    fontSize: 11, fontWeight: 700, color: TOKENS.white,
    flexShrink: 0,
  },
  userName: { fontSize: 12, fontWeight: 600, color: TOKENS.chromeText },
  userRole: { fontSize: 10, color: TOKENS.chromeTextDim, textTransform: "capitalize" },

  // Body
  body: { display: "flex", flex: 1, overflow: "hidden" },

  // Sidebar Nav
  // On phone the nav becomes a slide-over drawer (position:fixed, transform-translate).
  // On tablet/desktop it stays in-flow as a collapsible rail.
  nav: (collapsed, isPhone) => isPhone ? ({
    position: "fixed",
    top: 58, bottom: 0, left: 0,
    width: 260, maxWidth: "82vw",
    background: TOKENS.chromeBg,
    borderRight: `1px solid ${TOKENS.chromeBorder}`,
    display: "flex", flexDirection: "column",
    transform: collapsed ? "translateX(-100%)" : "translateX(0)",
    transition: "transform 0.22s ease",
    boxShadow: collapsed ? "none" : "4px 0 16px rgba(0,0,0,0.18)",
    overflow: "hidden",
    zIndex: 150,
  }) : ({
    width: collapsed ? 56 : 220,
    background: TOKENS.chromeBg,
    borderRight: `1px solid ${TOKENS.chromeBorder}`,
    display: "flex", flexDirection: "column",
    flexShrink: 0,
    transition: "width 0.2s ease",
    overflow: "hidden",
    zIndex: 50,
  }),
  // Backdrop scrim behind the phone drawer.
  navBackdrop: (open) => ({
    position: "fixed",
    top: 58, bottom: 0, left: 0, right: 0,
    background: "rgba(15, 23, 42, 0.45)",
    opacity: open ? 1 : 0,
    pointerEvents: open ? "auto" : "none",
    transition: "opacity 0.18s ease",
    zIndex: 140,
  }),
  // Hamburger trigger in the header (phone only).
  hamburger: {
    display: "flex", alignItems: "center", justifyContent: "center",
    width: 36, height: 36,
    border: "none", background: "transparent",
    borderRadius: 8, cursor: "pointer",
    color: TOKENS.chromeText,
    padding: 0, marginRight: 4,
  },
  navScroll: { flex: 1, overflowY: "auto", overflowX: "hidden", padding: "8px 0" },
  navDivider: { height: 1, background: TOKENS.chromeBorder, margin: "8px 12px" },
  navItem: (active, collapsed) => ({
    display: "flex", alignItems: "center",
    gap: collapsed ? 0 : 10,
    padding: collapsed ? "10px 0" : "9px 14px",
    justifyContent: collapsed ? "center" : "flex-start",
    cursor: "pointer",
    fontSize: 12.5, fontWeight: active ? 600 : 400,
    color: active ? TOKENS.chromeText : TOKENS.chromeTextDim,
    background: active ? TOKENS.chromeBgDeep : "transparent",
    borderLeft: active ? `3px solid ${TOKENS.chromeText}` : "3px solid transparent",
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
    borderTop: `1px solid ${TOKENS.chromeBorder}`,
    cursor: "pointer",
    color: TOKENS.chromeTextDim,
    transition: "color 0.15s",
  },
  navFooter: {
    padding: "8px 14px 12px",
    borderTop: `1px solid ${TOKENS.chromeBorder}`,
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
      background: TOKENS.slate50, fontFamily: "'Poppins', 'Helvetica Neue', sans-serif", padding: 20,
    }}>
      <div style={{
        width: "100%", maxWidth: 380, background: TOKENS.white,
        borderRadius: 16, padding: "32px 30px",
        boxShadow: "0 12px 40px rgba(0,0,0,0.25)",
      }}>
        {/* Logo + heading */}
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", marginBottom: 24 }}>
          <img src="/newt-icon-transparent.png" alt="paper newt" width="144" height="144" style={{ display: "block", marginBottom: 14 }} />
          <div style={{ fontFamily: '"Quicksand", "Poppins", sans-serif', fontSize: 26, fontWeight: 500, color: TOKENS.slate900, letterSpacing: "0.04em" }}>paper newt</div>
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
    <div style={{ minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center", background: TOKENS.slate50, fontFamily: "'Poppins', 'Helvetica Neue', sans-serif", padding: 20 }}>
      <div style={{ width: "100%", maxWidth: 380, background: TOKENS.white, borderRadius: 16, padding: "32px 30px", boxShadow: "0 12px 40px rgba(0,0,0,0.25)" }}>
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", marginBottom: 24 }}>
          <img src="/newt-icon-transparent.png" alt="paper newt" width="144" height="144" style={{ display: "block", marginBottom: 14 }} />
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
// All modules built. In production each is imported from src/modules/.
// This shell routes to each module component.
const ModuleRouter = ({ active, onNavigate, userRole, userId }) => {
  const modules = {
    dashboard:   <ErrorBoundary name="Dashboard"><Dashboard onNavigate={onNavigate} userRole={userRole} /></ErrorBoundary>,
    cpr:         <ErrorBoundary name="CPR"><CPRList /></ErrorBoundary>,
    financials:  <ErrorBoundary name="Financials"><Financials /></ErrorBoundary>,
    principles:  <ErrorBoundary name="Core Principles"><CorePrinciples /></ErrorBoundary>,
    handbook:    <ErrorBoundary name="Handbook"><Handbook /></ErrorBoundary>,
    playbook:    <ErrorBoundary name="Processes"><Playbook /></ErrorBoundary>,
    admin:       <ErrorBoundary name="Admin"><Admin /></ErrorBoundary>,
    memory:      <ErrorBoundary name="Memory"><PersistentMemory /></ErrorBoundary>,
    automations: <ErrorBoundary name="Automations"><Automations /></ErrorBoundary>,
    social:      <ErrorBoundary name="Social Media"><SocialMedia /></ErrorBoundary>,
    tasks:       <ErrorBoundary name="Tasks & Goals"><TasksGoals userRole={userRole} userId={userId} /></ErrorBoundary>,
    alerts:      <ErrorBoundary name="Alerts"><AlertsNotifications onNavigate={onNavigate} /></ErrorBoundary>,
    hr:          <ErrorBoundary name="Team"><HRPeople /></ErrorBoundary>,
    time:        <ErrorBoundary name="Time"><TimeHub /></ErrorBoundary>,
    settings:    <ErrorBoundary name="Settings"><Settings /></ErrorBoundary>,
    renewals:    <ErrorBoundary name="Renewals"><Renewals userRole={userRole} userId={userId} /></ErrorBoundary>,
    scorecards:  <ErrorBoundary name="FIT Scorecards"><FitScorecards userRole={userRole} userId={userId} /></ErrorBoundary>,
  };
  // Access guard — enforce nav role at the module level so direct URL
  // navigation (e.g. /financials) cannot bypass the sidebar filter. Mirrors
  // the same role check used by filteredNav in BCCApp(). Per-user module
  // overrides were dropped (migration 032 / 2026-06-22) — role-only now.
  const navItem = NAV_ITEMS.find(n => n.id === active);
  if (navItem) {
    const roleOk = !navItem.roles || navItem.roles.includes(userRole);
    if (!roleOk) {
      return <AccessDenied />;
    }
  }
  return modules[active] || <ComingSoon module={active} />;
};

const AccessDenied = () => (
  <div style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", flex: 1, gap: 12, padding: 40, textAlign: "center" }}>
    <div style={{ width: 56, height: 56, borderRadius: 16, background: TOKENS.slate100, display: "flex", alignItems: "center", justifyContent: "center" }}>
      <Icon name="shield" size={24} color={TOKENS.slate500} />
    </div>
    <div style={{ fontSize: 18, fontWeight: 700, color: TOKENS.slate900 }}>Restricted</div>
    <div style={{ fontSize: 13, color: TOKENS.slate500, maxWidth: 320, lineHeight: 1.6 }}>
      This section isn't available for your role. If you think this is a mistake, contact the agency owner.
    </div>
  </div>
);

// ─── URL ↔ App-state routing ──────────────────────────────────────────────────
// Maps the browser URL pathname to {module, cprWeekDate} so refresh stays on the
// same page. Vercel SPA fallback (vercel.json: /(.*) → /index.html) means any
// path serves index.html; this function then resolves it back to app state.
//   /                  → { module: "dashboard", cprWeekDate: null }
//   /<navItemId>       → { module: <navItemId>, cprWeekDate: null }
//   /cpr/YYYY-MM-DD    → { module: "cpr",       cprWeekDate: "YYYY-MM-DD" }
//   anything else      → { module: "dashboard", cprWeekDate: null }
const KNOWN_MODULE_IDS = NAV_ITEMS.filter(n => n.type !== "divider").map(n => n.id);
function parseUrl(pathname) {
  const p = (pathname || "/").replace(/\/+$/, "") || "/";
  const cprMatch = /^\/cpr\/(\d{4}-\d{2}-\d{2})$/.exec(p);
  if (cprMatch) return { module: "cpr", cprWeekDate: cprMatch[1] };
  if (p === "/" || p === "/dashboard") return { module: "dashboard", cprWeekDate: null };
  // Accept /<module> AND /<module>/<sub-path>. Modules like handbook, playbook,
  // and admin own their own sub-route (e.g. /handbook/<page-id>) — BCCApp only
  // resolves the top-level module here and leaves the sub-path to the module.
  const slugMatch = /^\/([a-z][a-z0-9-]*)(?:\/.*)?$/.exec(p);
  if (slugMatch && KNOWN_MODULE_IDS.includes(slugMatch[1])) {
    return { module: slugMatch[1], cprWeekDate: null };
  }
  return { module: "dashboard", cprWeekDate: null };
}
function urlForState(moduleId, cprWeekDate) {
  if (cprWeekDate) return `/cpr/${cprWeekDate}`;
  if (moduleId === "dashboard") return "/";
  return `/${moduleId}`;
}

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

  // Initial route read from the URL — refresh lands you on the same page.
  const _initialRoute = (typeof window !== "undefined")
    ? parseUrl(window.location.pathname)
    : { module: "dashboard", cprWeekDate: null };
  const [activeModule, setActiveModule] = useState(_initialRoute.module);
  // CPR detail deep-link state: set when URL matches /cpr/YYYY-MM-DD, cleared on close.
  const [cprWeekDate, setCprWeekDate] = useState(_initialRoute.cprWeekDate);
  // Browser back/forward: sync both pieces of state from the URL.
  useEffect(() => {
    if (typeof window === "undefined") return undefined;
    const onPop = () => {
      const r = parseUrl(window.location.pathname);
      setActiveModule(r.module);
      setCprWeekDate(r.cprWeekDate);
    };
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);
  // App-state → URL: any change to activeModule or cprWeekDate pushes the URL.
  // Every nav click, dashboard tile, and child-component onNavigate call routes
  // through this single effect, so there is no setActiveModule call site that
  // needs to know about URLs. Modules that own a sub-path (handbook/playbook/
  // admin, e.g. /handbook/<page-id>) manage that segment themselves — we only
  // push when the TOP-LEVEL module changes, not when the full path differs.
  useEffect(() => {
    if (typeof window === "undefined") return;
    const current = window.location.pathname || "/";
    const currentParsed = parseUrl(current);
    if (
      currentParsed.module === activeModule &&
      currentParsed.cprWeekDate === cprWeekDate
    ) {
      // URL already represents the same module — leave any sub-path intact.
      return;
    }
    const desired = urlForState(activeModule, cprWeekDate);
    if (current !== desired) {
      window.history.pushState({}, "", desired);
    }
  }, [activeModule, cprWeekDate]);

  // Navigate to a specific CPR week. URL sync happens in the activeModule/cprWeekDate effect.
  const handleNavigateCPRWeek = (newDateISO) => {
    if (!newDateISO || !/^\d{4}-\d{2}-\d{2}$/.test(newDateISO)) return;
    setActiveModule("cpr");
    setCprWeekDate(newDateISO);
  };

  // Close the CPR detail page → land on the CPR list at /cpr (the URL effect pushes it).
  const handleCloseCPR = () => {
    setActiveModule("cpr");
    setCprWeekDate(null);
  };
  const viewport = useViewport();
  // Sidebar starts collapsed on phone/tablet (manual toggle still works thereafter).
  const [navCollapsed, setNavCollapsed] = useState(() => {
    if (typeof window === "undefined") return false;
    return window.innerWidth < 1024;
  });
  const [userMenuOpen, setUserMenuOpen] = useState(false);
  const [agency, setAgency] = useState(AGENCY_DEFAULTS);

  // Check for an existing session on mount, and subscribe to auth changes.
  useEffect(() => {
    let mounted = true;
    if (!supabase) {
      // No client at all — fail open to the app (data still reads via anon),
      // rather than locking the user out of a misconfigured build.
      setAuthState("in");
      return;
    }

    // Race any supabase call against a timeout so a hung network (corp WiFi
    // blocking the project subdomain, slow proxy, etc.) can't pin the auth
    // gate on "checking" forever. The real promise keeps running in the
    // background; if it ever resolves, the auth state will update via
    // onAuthStateChange. Worst case the user falls through to LoginScreen
    // after the timeout and can try signing in manually.
    const withTimeout = (promise, ms, fallback) => Promise.race([
      promise,
      new Promise((resolve) => setTimeout(() => resolve(fallback), ms)),
    ]);

    // Belt-and-suspenders invite detection. The URL-hash regex below races with
    // Supabase JS auto-consuming the hash on construction (invite flow gives us
    // a SIGNED_IN event, not PASSWORD_RECOVERY, so the hash is the only fast
    // signal — and it often loses the race). This DB check is the authoritative
    // fallback: any logged-in user whose public.users.invite_status is still
    // 'invited' has not finished onboarding and needs the SetPasswordScreen.
    const checkInviteStatus = async (authUserId) => {
      if (!authUserId) return false;
      try {
        const result = await withTimeout(
          supabase
            .from("users")
            .select("invite_status")
            .eq("auth_user_id", authUserId)
            .maybeSingle(),
          3000,
          { data: null },
        );
        return result?.data?.invite_status === "invited";
      } catch (_e) {
        return false;
      }
    };

    withTimeout(
      supabase.auth.getSession(),
      8000,
      { data: { session: null } },
    ).then(async ({ data }) => {
      if (!mounted) return;
      const session = data?.session || null;
      setSessionEmail(session?.user?.email || "");
      if (session?.user?.id && await checkInviteStatus(session.user.id)) {
        if (mounted) setNeedsPassword(true);
      }
      if (mounted) setAuthState(session ? "in" : "out");
    }).catch(() => {
      if (mounted) setAuthState("out");
    });

    const { data: sub } = supabase.auth.onAuthStateChange(async (event, session) => {
      if (!mounted) return;
      setSessionEmail(session?.user?.email || "");
      // Fast-path triggers: PASSWORD_RECOVERY event (Supabase fires this for
      // recovery links) and the URL hash regex (catches invite/signup when we
      // win the race against hash-strip).
      if (event === "PASSWORD_RECOVERY") setNeedsPassword(true);
      const hash = (typeof window !== "undefined" && window.location.hash) || "";
      if (/type=(invite|recovery|signup)/.test(hash)) setNeedsPassword(true);
      // Authoritative check: anyone with invite_status='invited' needs to set
      // a password before entering, regardless of how they signed in.
      if (session?.user?.id && await checkInviteStatus(session.user.id)) {
        if (mounted) setNeedsPassword(true);
      }
      if (mounted) setAuthState(session ? "in" : "out");
    });

    return () => {
      mounted = false;
      sub?.subscription?.unsubscribe?.();
    };
  }, []);

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
          .select("id, full_name, role, email")
          .eq("agency_id", AGENCY_ID)
          .ilike("email", email)
          .limit(1);
        profile = (rows && rows[0]) || null;
      }

      // SECURITY: default to "staff" (team-tier, restricted) if no profile row.
      // Previously fell back to "owner" — meant any authed user without a users
      // row got full admin access. Standing rule: deny by default.
      const role = profile?.role || "staff";
      const displayName = profile?.full_name || ag?.owner_name || AGENCY_DEFAULTS.user.name;
      setAgency({
        name: ag?.name || AGENCY_DEFAULTS.name,
        agentCode: ag?.state_farm_agent_code || AGENCY_DEFAULTS.agentCode,
        user: {
          id: profile?.id || null,
          name: displayName,
          initials: (displayName || "?").split(" ").map(n => n?.[0] || "").join("").toUpperCase().slice(0,2),
          role,
          email: profile?.email || ag?.primary_email || sessionEmail || AGENCY_DEFAULTS.user.email,
        },
        alerts: AGENCY_DEFAULTS.alerts,
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
  // First pass: filter by role, keeping divider sentinels.
  const filteredNav = NAV_ITEMS.filter(n => {
    if (n.type === "divider") return true;
    return n.roles.includes(agency.user.role);
  });
  // Second pass: drop dividers that would render as visual artifacts
  // (leading, trailing, or adjacent to another divider after filtering).
  const visibleNav = [];
  for (let i = 0; i < filteredNav.length; i++) {
    const item = filteredNav[i];
    if (item.type === "divider") {
      if (visibleNav.length === 0) continue;
      if (visibleNav[visibleNav.length - 1].type === "divider") continue;
      const hasAfter = filteredNav.slice(i + 1).some(x => x.type !== "divider");
      if (!hasAfter) continue;
    }
    visibleNav.push(item);
  }

  return (
    <AppContext.Provider value={{ agency, activeModule, setActiveModule }}>
      <div style={css.app}>
        <DemoBanner />

        {/* ── Header ── */}
        <header style={{ ...css.header, padding: viewport.isPhone ? "0 8px" : "0 20px" }}>
          <div style={css.headerLeft}>
            {viewport.isPhone && (
              <button
                type="button"
                aria-label={navCollapsed ? "Open navigation" : "Close navigation"}
                aria-expanded={!navCollapsed}
                style={css.hamburger}
                onClick={() => setNavCollapsed(c => !c)}
              >
                <Icon name={navCollapsed ? "menu" : "x"} size={20} color={TOKENS.chromeText} />
              </button>
            )}
            <div style={css.headerLogo}>
              <img
                src="/paper-newt-master.png"
                alt="paper newt"
                width={viewport.isPhone ? 88 : 136}
                height={viewport.isPhone ? 36 : 56}
                style={{ display: "block" }}
              />
            </div>
            {!viewport.isPhone && (
              <div>
                <div style={css.agencyName}>paper newt</div>
              </div>
            )}
          </div>

          <div style={css.headerRight}>
            {/* Alerts Bell */}
            <div style={css.bellWrap} title={`${agency.alerts} active alerts`}>
              <Icon name="bell" size={18} color={TOKENS.chromeText} />
              {agency.alerts > 0 && <span style={css.bellBadge}>{agency.alerts}</span>}
            </div>

            {/* User Menu */}
            <div style={{ position: "relative" }}>
              <div
                style={css.userPill}
                onClick={() => setUserMenuOpen(o => !o)}
              >
                <div style={css.avatar}>{agency.user.initials}</div>
                {!viewport.isPhone && (
                  <div>
                    <div style={css.userName}>{agency.user.name}</div>
                    <div style={css.userRole}>{agency.user.role}</div>
                  </div>
                )}
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
                      onClick={() => { if (cprWeekDate) handleCloseCPR(); setActiveModule("settings"); setUserMenuOpen(false); }}>
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

        {/* ── Agency Identity Ribbon — persistent below header on every route ── */}
        <AgencyIdentityRibbon />

        {/* ── Body ── */}
        <div style={css.body} onClick={() => userMenuOpen && setUserMenuOpen(false)}>

          {/* Backdrop scrim for the phone drawer */}
          {viewport.isPhone && (
            <div
              style={css.navBackdrop(!navCollapsed)}
              onClick={() => setNavCollapsed(true)}
              aria-hidden={navCollapsed}
            />
          )}

          {/* ── Sidebar ── */}
          <nav
            style={css.nav(navCollapsed, viewport.isPhone)}
            aria-hidden={viewport.isPhone && navCollapsed}
          >
            <div style={css.navScroll}>
              {visibleNav.map(item => {
                if (item.type === "divider") {
                  return <div key={item.id} style={css.navDivider} aria-hidden="true" />;
                }
                const active = activeModule === item.id;
                // On phone the nav is always rendered expanded inside the drawer,
                // so force collapsed=false for nav-item styling there.
                const itemCollapsed = viewport.isPhone ? false : navCollapsed;
                return (
                  <div
                    key={item.id}
                    style={css.navItem(active, itemCollapsed)}
                    onClick={() => {
                      if (cprWeekDate) handleCloseCPR();
                      setActiveModule(item.id);
                      if (viewport.isPhone) setNavCollapsed(true);
                    }}
                    title={itemCollapsed ? item.label : ""}
                  >
                    <Icon
                      name={item.icon}
                      size={15}
                      color={active ? TOKENS.chromeText : TOKENS.chromeTextDim}
                    />
                    <span style={css.navLabel(itemCollapsed)}>{item.label}</span>
                    {item.id === "alerts" && !itemCollapsed && agency.alerts > 0 && (
                      <span style={{ ...css.pill("danger"), marginLeft: "auto", fontSize: 9, padding: "2px 6px" }}>
                        {agency.alerts}
                      </span>
                    )}
                  </div>
                );
              })}
            </div>

            {/* Collapse Toggle — tablet/desktop only; phone drawer closes via tap-item / backdrop / header X */}
            {!viewport.isPhone && (
              <div
                style={css.navCollapseBtn}
                onClick={() => setNavCollapsed(c => !c)}
                title={navCollapsed ? "Expand navigation" : "Collapse navigation"}
              >
                <Icon name={navCollapsed ? "chevronRight" : "chevronLeft"} size={14} color={TOKENS.chromeTextDim} />
              </div>
            )}
          </nav>

          {/* ── Main Content ── */}
          <main style={css.main}>
            <div style={{ ...css.mainInner, padding: viewport.isPhone ? "12px 12px" : viewport.isTablet ? "16px 18px" : "20px 24px" }}>
              {cprWeekDate ? (
                <ErrorBoundary name="CPR Detail"><CPRDetail weekDate={cprWeekDate} onClose={handleCloseCPR} onNavigateWeek={handleNavigateCPRWeek} userRole={agency?.user?.role} /></ErrorBoundary>
              ) : (
                <ModuleRouter active={activeModule} onNavigate={setActiveModule} userRole={agency.user.role} userId={agency.user.id} />
              )}
            </div>

            {/* Footer */}
            <div style={css.footer}>
              paper newt
            </div>
          </main>
        </div>
      </div>
    </AppContext.Provider>
  );
}
