// =========================================================================
// Onboarding.jsx
// =========================================================================
// Who sees what (Peter 2026-09-21), enforced in the database by
// onboarding_can_see_step / onboarding_can_see_plan:
//   * Admins (owner, manager) see every plan and every card.
//   * The person a plan is for sees every card from Day 1 forward.
//   * Anyone a card is assigned to sees that card. The references card is
//     assigned to whoever is calling that candidate's references, and the
//     calling list lives on that card.
// The UI shows whatever the database returns. It does not filter again.
//
// Data: team_onboarding_plans + team_onboarding_steps.
// Plan creation compiles from onboarding_step_templates via RPC
// create_onboarding_plan_from_templates(team_member_id, start_date, notes).
// Template edits flow straight into every active or paused plan through
// onboarding_sync_plan() — ticks, notes and completed steps are kept.
// Sub-items with pop-up instructions match onboarding_instructions by label.
//
// RLS on the underlying tables enforces admin RW / team-tier read-own +
// update-own-steps. This UI mirrors that scoping.
// =========================================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { TabLink, useTabParam, hrefWithParams } from "../lib/routing.jsx";
import { useViewport } from "../lib/hooks.js";
import { mdToHtml } from "../lib/markdown.js";
import InfoDot from "../components/InfoDot.jsx";
import {
  Card, Pill, Button, fieldLabel, inputBase, trackHeadStyle,
  CATEGORY_COLORS, STAGE_LABELS, STATUS_COLORS,
  subGroups, subProgress, trackColumns, wrapLongText, LabelText, GroupHead, formIdOf, FormPopupProvider, ItemInfo,
  splitIndent, columnStyle, bannerStyle, fmtDate, setStepDone, setSubstepDone, ORIENTATION_KIND,
} from "../lib/onboardingUi.jsx";
import OnboardingTemplateEditor from "../components/OnboardingTemplateEditor.jsx";
import OrientationPopup from "../components/OrientationPopup.jsx";
import ReferenceCalls from "./ReferenceCalls.jsx";

// ─── constants ─────────────────────────────────────
const ADMIN_ROLES = ["owner", "admin"];

// Week bands match the ramp table the agency has always run on: 1-2, 3-4,
// 5-8, 9-13, 14+. The earlier labels here (Week 1 / Weeks 2-3 / Month 2 /
// Month 3) did not line up with the steps sitting in each phase.
// Fallback only. The real phase list lives in onboarding_phases so milestones
// can be added without a deploy.
const PHASE_LABELS = {
  10: { name: "Before start",                blurb: "Everything before Day 1." },
  15: { name: "References and background",   blurb: "Runs as soon as they reply to the offer email." },
  20: { name: "Two weeks before start",      blurb: "System access, equipment, cards, nameplate." },
  25: { name: "Once they have an alias",     blurb: "Softphone and logins." },
  30: { name: "Once they have an extension", blurb: "Team list and call flow." },
  35: { name: "Workspace ready",             blurb: "Desk, hardware, keys. Confirmed working before Day 1." },
  40: { name: "Friday before start",         blurb: "Welcome call, schedule, printed packet." },
  50: { name: "Tech setup",                  blurb: "Log in first. The other tech cards and Weeks 1-2 open once Login is done." },
  55: { name: "Weeks 1-2",                   blurb: "Orientation, courses, shadowing. No production target." },
  60: { name: "Weeks 3-4",                   blurb: "First independent work, daily wrap-ups, weekly 1:1s." },
  65: { name: "Weeks 5-8",                   blurb: "Review cadence begins, Life pipeline starts, half shadow." },
  70: { name: "Weeks 9-13",                  blurb: "Full quote share, weekly claims rhythm, cross-training." },
  75: { name: "Week 14+",                    blurb: "Fully independent. Champions Circle pace, monthly audit rhythm." },
};

// ─── data hooks ─────────────────────────────────────

function useOnboardingData(userId, isAdmin) {
  const [state, setState] = useState({
    loading: true, error: null,
    plans: [],           // all plans visible to this user
    steps: [],           // all steps for those plans
    team: [],            // full active roster (for admin create form + name resolution)
    phases: [],          // onboarding_phases — milestone list, newest source of truth
    candidates: [],      // hiring candidates a plan can be started on at offer
    myTeamMemberId: null,
    planNames: {},       // plan_id -> name, for plans a teammate can see but whose person they cannot look up
    instructions: {},    // sub-item label -> { title, body_md } pop-up instructions
    icons: {},           // sub-item label -> icon url, shown after the text
  });

  const load = useCallback(async () => {
    if (!supabase || !AGENCY_ID) {
      setState(s => ({ ...s, loading: false, error: "Supabase not configured." }));
      return;
    }
    try {
      const [plansRes, teamRes, phasesRes, candsRes, instrRes, iconRes] = await Promise.all([
        supabase.from("team_onboarding_plans")
          .select("id, agency_id, team_member_id, candidate_id, attached_at, role_snapshot, role_category_snapshot, role_level_snapshot, start_date, status, notes, created_by, created_at, updated_at")
          .eq("agency_id", AGENCY_ID)
          .order("created_at", { ascending: false }),
        supabase.from("team_directory")
          .select("id, first_name, last_name, nickname, role, role_category, role_level, category, is_active, is_admin_backoffice, is_test_user, archived_at, user_id, start_date")
          .eq("agency_id", AGENCY_ID),
        supabase.from("onboarding_phases")
          .select("phase, name, blurb, stage, weeks_long, week_titles")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true)
          .order("phase", { ascending: true }),
        supabase.from("hiring_candidates")
          .select("id, candidate_name, first_name, last_name, status, offer_job_title, offer_role_key, offer_start_date")
          .eq("agency_id", AGENCY_ID)
          .in("status", ["reference_check", "offer"]),
        supabase.from("onboarding_instructions")
          .select("id, substep_label, title, body_md, kind")
          .eq("agency_id", AGENCY_ID),
        supabase.from("onboarding_substep_icons")
          .select("substep_label, icon_url")
          .eq("agency_id", AGENCY_ID),
      ]);

      const plans = plansRes.data || [];
      const team = teamRes.data || [];
      const phases = phasesRes.data || [];
      const candidates = candsRes.data || [];
      const instructions = {};
      (instrRes.data || []).forEach(r => { instructions[r.substep_label] = r; });
      const icons = {};
      (iconRes.data || []).forEach(r => { icons[r.substep_label] = r.icon_url; });

      let steps = [];
      if (plans.length) {
        const planIds = plans.map(p => p.id);
        const stepsRes = await supabase.from("team_onboarding_steps")
          .select("id, plan_id, template_key, title, description, phase, category, source_manual_id, source_anchor, sort_order, is_required, completed_at, completed_by, notes, substeps, substeps_done, owner_kind, assigned_to, task_id, track, track_order, blocked_by, auto_source, auto_summary, unlock_rule, unlocks_on, widget, assign_role_category, week_no, full_width")
          .in("plan_id", planIds)
          .order("phase", { ascending: true })
          .order("sort_order", { ascending: true });
        steps = stepsRes.data || [];
      }

      const namesRes = await supabase.rpc("onboarding_visible_plan_names");
      const planNames = {};
      (namesRes.data || []).forEach(r => { planNames[r.plan_id] = r.subject_name; });

      let myTeamMemberId = null;
      if (userId) {
        const mine = team.find(t => t.user_id === userId);
        myTeamMemberId = mine?.id || null;
      }

      setState({ loading: false, error: null, plans, steps, team, phases, candidates, myTeamMemberId, planNames, instructions, icons });
    } catch (e) {
      setState(s => ({ ...s, loading: false, error: e.message || "Failed to load onboarding data." }));
    }
  }, [userId]);

  useEffect(() => { load(); }, [load]);

  return { ...state, reload: load };
}

// ─── name/date helpers ────────────────────────────────
function memberName(t) {
  if (!t) return "Unknown teammate";
  const nick = t.nickname && t.nickname.trim();
  const first = nick || t.first_name || "";
  const last = t.last_name || "";
  return `${first} ${last}`.trim() || "Unknown";
}

function daysBetween(startISO, endISO = null) {
  if (!startISO) return null;
  const start = new Date(startISO + (startISO.length === 10 ? "T00:00:00" : ""));
  const end = endISO ? new Date(endISO + (endISO.length === 10 ? "T00:00:00" : "")) : new Date();
  return Math.floor((end - start) / (1000 * 60 * 60 * 24));
}

function progress(steps) {
  if (!steps.length) return { done: 0, total: 0, pct: 0, req_done: 0, req_total: 0, req_pct: 0 };
  const done = steps.filter(s => s.completed_at).length;
  const total = steps.length;
  const required = steps.filter(s => s.is_required);
  const req_done = required.filter(s => s.completed_at).length;
  const req_total = required.length;
  return {
    done, total, pct: Math.round((done / total) * 100),
    req_done, req_total,
    req_pct: req_total ? Math.round((req_done / req_total) * 100) : 100,
  };
}

// ─── plan detail (steps by phase/category) ───────────────
// ─── pop-up instructions for a sub-item ─────────────
function InstructionsModal({ item, onClose }) {
  if (!item) return null;
  return (
    <div
      onClick={onClose}
      style={{
        position: "fixed", inset: 0, background: "rgba(15,23,42,0.45)",
        display: "flex", alignItems: "center", justifyContent: "center",
        padding: 16, zIndex: 1000, boxSizing: "border-box",
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: T.white, borderRadius: 12, padding: "18px 20px",
          width: "100%", maxWidth: 640, maxHeight: "85vh",
          overflowY: "auto", overflowX: "hidden", boxSizing: "border-box",
          boxShadow: "0 20px 50px rgba(0,0,0,0.25)", ...wrapLongText,
        }}
      >
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 10, marginBottom: 8 }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>{item.title}</div>
          <Button variant="secondary" onClick={onClose}>Close</Button>
        </div>
        <div
          style={{ fontSize: 13, color: T.slate700, lineHeight: 1.55 }}
          dangerouslySetInnerHTML={{ __html: mdToHtml(item.body_md || "") }}
        />
      </div>
    </div>
  );
}

function PlanDetail({ plan, subjectName, isCandidate, steps, onBack, onToggleStep, onToggleSubstep, onUpdateStepNotes, onDeletePlan, onChangeStatus, isAdmin, isOwner = false, userId = null, onReload = null, phaseMeta, ownerName, instructions = {}, icons = {}, showBack = true }) {
  const [expandedStep, setExpandedStep] = useState(null);
  // The orientation pop-up that is open (owner only): its instructions row.
  const [orientation, setOrientation] = useState(null);
  // step id -> true when someone chose the archived way of doing a line.
  const [altOn, setAltOn] = useState({});
  const todayCT = new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
  const [openInstr, setOpenInstr] = useState(null);
  const [editingNote, setEditingNote] = useState(null); // {stepId, text}
  const [savingId, setSavingId] = useState(null);
  const p = progress(steps);

  // One major card per phase, and one per week for a phase that spans weeks.
  const byPhase = useMemo(() => {
    const map = new Map();
    steps.forEach(s => {
      const key = `${s.phase}|${s.week_no ?? ""}`;
      if (!map.has(key)) map.set(key, { key, phase: s.phase, week: s.week_no ?? null, steps: [] });
      map.get(key).steps.push(s);
    });
    return [...map.values()].sort((a, b) => a.phase - b.phase || (a.week ?? 0) - (b.week ?? 0));
  }, [steps]);

  // template_key -> title, for every step in this plan that is not done yet.
  // Anything listing one of these as a blocker stays locked.
  const blockersOpen = useMemo(() => {
    const m = new Map();
    steps.forEach(s => { if (!s.completed_at && s.template_key) m.set(s.template_key, s.title); });
    return m;
  }, [steps]);

  // Whether a step is waiting: on a step before it, or on the day it opens.
  const stepLock = useCallback((step) => {
    const done = !!step.completed_at;
    const waitingOn = (step.blocked_by || [])
      .filter(k => blockersOpen.has(k))
      .map(k => blockersOpen.get(k));
    const notYet = !done && !!step.unlocks_on && step.unlocks_on > todayCT;
    return { done, waitingOn, notYet, locked: !done && (waitingOn.length > 0 || notYet) };
  }, [blockersOpen, todayCT]);

  // Major cards start folded and open by themselves once a subcard in them
  // opens; a click on the header overrides either way.
  const [cardOpen, setCardOpen] = useState({});

  const handleToggle = async (step) => {
    setSavingId(step.id);
    try { await onToggleStep(step); } finally { setSavingId(null); }
  };

  const handleSaveNote = async (stepId) => {
    setSavingId(stepId);
    try {
      await onUpdateStepNotes(stepId, editingNote.text);
      setEditingNote(null);
    } finally { setSavingId(null); }
  };

  const statusCol = STATUS_COLORS[plan.status] || STATUS_COLORS.active;

  return (
    <div>
      {/* Header */}
      {showBack && <div style={{ marginBottom: 16 }}>
        <a
          href="/development"
          onClick={(e) => {
            if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
            e.preventDefault();
            onBack();
          }}
          style={{ fontSize: 12, color: T.slate500, textDecoration: "none", display: "inline-flex", alignItems: "center", gap: 4 }}
        >← All schedules</a>
      </div>}

      <Card style={{ marginBottom: 14 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12, flexWrap: "wrap" }}>
          <div style={{ flex: 1, minWidth: 240 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 6 }}>
              <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900, letterSpacing: "-0.02em" }}>
                {subjectName}
              </div>
              <Pill fg={statusCol.fg} bg={statusCol.bg}>{statusCol.label}</Pill>
              {isCandidate && <Pill fg={T.purple} bg={T.purpleLt}>Not on the team yet</Pill>}
            </div>
            <div style={{ fontSize: 12, color: T.slate500 }}>
              {plan.role_snapshot || "—"}
              {plan.role_category_snapshot ? ` · ${plan.role_category_snapshot}` : ""}
              {plan.role_level_snapshot ? ` · ${plan.role_level_snapshot}` : ""}
            </div>
            <div style={{ fontSize: 12, color: T.slate500, marginTop: 2 }}>
              Started {fmtDate(plan.start_date)} · Day {daysBetween(plan.start_date)}
            </div>
            {plan.notes ? (
              <div style={{ fontSize: 12, color: T.slate600, marginTop: 8, padding: "8px 10px", background: T.slate50, borderRadius: 6 }}>
                {plan.notes}
              </div>
            ) : null}
          </div>

          <div style={{ textAlign: "right" }}>
            <div style={{ fontSize: 28, fontWeight: 700, color: p.pct === 100 ? T.green : T.amber, letterSpacing: "-0.02em" }}>{p.pct}%</div>
            <div style={{ fontSize: 10, color: T.slate500 }}>{p.done}/{p.total} steps</div>
            <div style={{ fontSize: 10, color: T.slate400, marginTop: 2 }}>{p.req_done}/{p.req_total} required</div>
          </div>
        </div>

        {/* Progress bar */}
        <div style={{ marginTop: 14, height: 6, background: T.slate100, borderRadius: 3, overflow: "hidden" }}>
          <div style={{ height: "100%", width: `${p.pct}%`, background: p.pct === 100 ? T.green : T.blue, transition: "width 0.4s" }} />
        </div>

        {/* Admin actions */}
        {isAdmin ? (
          <div style={{ marginTop: 14, display: "flex", gap: 8, flexWrap: "wrap" }}>
            {plan.status === "active" && (
              <Button variant="secondary" onClick={() => onChangeStatus(plan.id, "paused")}>Pause</Button>
            )}
            {plan.status === "paused" && (
              <Button variant="secondary" onClick={() => onChangeStatus(plan.id, "active")}>Resume</Button>
            )}
            {plan.status !== "completed" && p.req_pct === 100 && (
              <Button variant="primary" onClick={() => onChangeStatus(plan.id, "completed")}>Mark completed</Button>
            )}
            {plan.status === "completed" && (
              <Button variant="secondary" onClick={() => onChangeStatus(plan.id, "archived")}>Archive</Button>
            )}
            <Button variant="danger" onClick={() => onDeletePlan(plan.id)} style={{ marginLeft: "auto" }}>Delete plan</Button>
          </div>
        ) : null}
      </Card>

      <InstructionsModal item={openInstr} onClose={() => setOpenInstr(null)} />
      {orientation && (
        <OrientationPopup
          instruction={orientation}
          userId={userId}
          onClose={() => { setOrientation(null); if (onReload) onReload(); }}
        />
      )}

      {/* Phases */}
      {byPhase.map(({ key: cardKey, phase, week, steps: phaseSteps }) => {
        const meta = phaseMeta(phase);
        const phaseP = progress(phaseSteps);
        const cardName = meta.weeksLong > 1 && week
          ? `Week ${week}${meta.weekTitles[String(week)] ? `: ${meta.weekTitles[String(week)]}` : ""}`
          : meta.name;
        const anyOpen = phaseSteps.some(s => { const l = stepLock(s); return !l.done && !l.locked; });
        const isOpen = cardOpen[cardKey] ?? anyOpen;
        const nextOpens = phaseSteps
          .filter(s => !s.completed_at && s.unlocks_on && s.unlocks_on > todayCT)
          .map(s => s.unlocks_on).sort()[0];

        return (
          <Card key={cardKey} style={{ marginBottom: 12 }}>
            <div
              role="button" tabIndex={0}
              onClick={() => setCardOpen(o => ({ ...o, [cardKey]: !isOpen }))}
              onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); setCardOpen(o => ({ ...o, [cardKey]: !isOpen })); } }}
              style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 10, marginBottom: isOpen ? 12 : 0, flexWrap: "wrap", cursor: "pointer" }}
            >
              <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                <span style={{ fontSize: 11, color: T.slate400, width: 10 }}>{isOpen ? "▾" : "▸"}</span>
                <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{cardName}</div>
                {meta.stage && STAGE_LABELS[meta.stage] && (
                  <Pill fg={STAGE_LABELS[meta.stage].fg} bg={STAGE_LABELS[meta.stage].bg}>
                    {STAGE_LABELS[meta.stage].label}
                  </Pill>
                )}
                {isOpen && meta.blurb && <div style={{ fontSize: 11, color: T.slate500, flexBasis: "100%" }}>{meta.blurb}</div>}
              </div>
              <div style={{ fontSize: 11, color: T.slate500 }}>
                {!isOpen && !anyOpen && nextOpens ? `Opens ${fmtDate(nextOpens)} · ` : ""}{phaseP.done}/{phaseP.total}
              </div>
            </div>

            {isOpen && (() => {
            const renderStep = (step) => {
                const cc = CATEGORY_COLORS[step.category] || { fg: T.slate600, bg: T.slate100, label: step.category || "Step" };
                const isExpanded = expandedStep === step.id;
                // Finished cards fold down to one line; a click opens them back up.
                const collapsed = !!step.completed_at && !isExpanded;
                const isEditingThis = editingNote?.stepId === step.id;
                const isSaving = savingId === step.id;
                const groups = subGroups(step.substeps);
                const subsDone = Array.isArray(step.substeps_done) ? step.substeps_done : [];
                const sp = subProgress(step.substeps, subsDone);
                // Some steps open on a date (the Friday before start, the
                // Monday their week starts), not just when the steps before
                // them are done.
                const { done, waitingOn, notYet, locked } = stepLock(step);
                // A line with an archived alternative. Show the alternative
                // when chosen, or when any of it is already ticked.
                const altGroups = groups.filter(g => g.altFor);
                // line -> its own (i) lines, across every group on the card
                const itemInfo = Object.assign({}, ...groups.map(g => g.itemInfo));
                const altActive = altGroups.length > 0 && (altOn[step.id] ??
                  altGroups.some(g => g.items.some(i => subsDone.includes(i))));
                const altToggle = altGroups.length > 0 && (
                  <button
                    onClick={(e) => { e.stopPropagation(); setAltOn(m => ({ ...m, [step.id]: !altActive })); }}
                    style={{
                      background: "none", border: "none", padding: 0, marginLeft: 8,
                      fontSize: 11, fontWeight: 600, color: T.blue, cursor: "pointer",
                      textTransform: "none", letterSpacing: 0,
                    }}
                  >{altActive ? "Use the current process instead"
                    : `Work ${(altGroups[0].group || "archived").toLowerCase()} process instead`}</button>
                );
                const altFor = new Set(altGroups.map(g => g.altFor));
                // Some steps fill themselves in from elsewhere in Newtworks.
                // They carry a short summary instead of hand checkboxes.
                const isAuto = !!step.auto_source;
                const autoSum = step.auto_summary && typeof step.auto_summary === "object" ? step.auto_summary : null;
                // A step with sub-items cannot be ticked until they are all ticked.
                const gated = !done && !isAuto && sp.total > 0 && !sp.complete;
                const boxOff = locked || gated || isAuto;

                return (
                  <div key={step.id} style={{
                    border: `1px solid ${locked ? T.slate100 : T.slate200}`, borderRadius: 8,
                    padding: "10px 12px", boxSizing: "border-box",
                    background: done ? T.slate50 : T.white,
                    opacity: locked ? 0.55 : 1,
                  }}>
                    <div style={{ display: "flex", alignItems: "flex-start", gap: 10, ...wrapLongText }}>
                      <button
                        onClick={() => { if (!boxOff) handleToggle(step); }}
                        disabled={isSaving || boxOff}
                        style={{
                          width: 20, height: 20, borderRadius: 4, flexShrink: 0, boxSizing: "border-box",
                          background: done ? T.green : T.white,
                          border: `1.5px solid ${done ? T.green : T.slate300}`,
                          cursor: boxOff ? "not-allowed" : (isSaving ? "wait" : "pointer"),
                          display: "flex", alignItems: "center", justifyContent: "center",
                          marginTop: 1,
                        }}
                        title={
                          isAuto ? "This one fills itself in"
                          : gated ? `Finish all ${sp.total} sub-items first`
                          : done ? "Mark incomplete" : "Mark complete"
                        }
                      >
                        {done && <span style={{ color: T.white, fontSize: 11, lineHeight: 1 }}>✓</span>}
                      </button>

                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 8, minWidth: 0 }}>
                          <div
                            onClick={() => setExpandedStep(isExpanded ? null : step.id)}
                            style={{
                              fontSize: 13, fontWeight: 600,
                              color: done ? T.slate500 : T.slate900,
                              textDecoration: done ? "line-through" : "none",
                              cursor: "pointer", lineHeight: 1.4,
                            }}
                          >
                            {step.title}
                            {!collapsed && !locked && groups.some(g => !g.group && !g.altFor && g.items.some(i => altFor.has(i))) && altToggle}
                            {!step.is_required && (
                              <span style={{ marginLeft: 8, fontSize: 10, color: T.slate400, fontWeight: 500 }}>optional</span>
                            )}
                            {instructions[step.title] && instructions[step.title].kind !== ORIENTATION_KIND && (
                              <span onClick={(e) => e.stopPropagation()} style={{ marginLeft: 6, display: "inline-block", verticalAlign: "middle" }}>
                                <InfoDot title="Instructions" onClick={() => setOpenInstr(instructions[step.title])} />
                              </span>
                            )}
                          </div>
                          <div style={{ display: "flex", gap: 4, flexShrink: 0, flexWrap: "wrap", justifyContent: "flex-end" }}>
                            {step.owner_kind !== "new_hire" && (
                              <Pill fg={T.purple} bg={T.purpleLt}>{ownerName(step)}</Pill>
                            )}
                            <Pill fg={cc.fg} bg={cc.bg}>{cc.label}</Pill>
                          </div>
                        </div>

                        {!collapsed && step.description && (
                          <div style={{ fontSize: 11, color: T.slate500, marginTop: 3, lineHeight: 1.45 }}>
                            <LabelText text={step.description} pathColor={T.teal} linkColor={T.blue} />
                          </div>
                        )}

                        {!collapsed && locked && waitingOn.length > 0 && (
                          <div style={{ fontSize: 11, color: T.amber, marginTop: 4, fontWeight: 600 }}>
                            Waiting on: {waitingOn.join(", ")}
                          </div>
                        )}
                        {!collapsed && notYet && (
                          <div style={{ fontSize: 11, color: T.amber, marginTop: 4, fontWeight: 600 }}>
                            Opens {fmtDate(step.unlocks_on)}
                          </div>
                        )}

                        {!collapsed && !locked && isAuto && (
                          <div style={{
                            marginTop: 8, padding: "8px 10px",
                            background: T.slate50, border: `1px solid ${T.slate200}`,
                            borderRadius: 6,
                          }}>
                            {autoSum ? (
                              <>
                                <div style={{
                                  fontSize: 12, fontWeight: 600,
                                  color: autoSum.complete ? T.green : T.amber,
                                }}>
                                  {autoSum.positive} of {autoSum.minimum} positive
                                  {" · "}{autoSum.count} of {autoSum.asked_for} back
                                </div>
                                {(Array.isArray(autoSum.items) ? autoSum.items : []).map((it, i) => (
                                  <div key={i} style={{
                                    marginTop: 8, paddingTop: i === 0 ? 0 : 8,
                                    borderTop: i === 0 ? "none" : `1px solid ${T.slate200}`,
                                    ...wrapLongText,
                                  }}>
                                    <div style={{ display: "flex", gap: 6, alignItems: "baseline", flexWrap: "wrap" }}>
                                      <span style={{ fontSize: 11, fontWeight: 600, color: T.slate800 }}>{it.referee}</span>
                                      {it.received && <span style={{ fontSize: 10, color: T.slate400 }}>{it.received}</span>}
                                      <Pill
                                        fg={it.positive ? T.green : T.amber}
                                        bg={it.positive ? T.greenLt : T.amberLt}
                                      >{it.positive ? "Positive" : "Not counted"}</Pill>
                                    </div>
                                    {Array.isArray(it.red_flags) && it.red_flags.length > 0 && (
                                      <div style={{ marginTop: 4 }}>
                                        {it.red_flags.map((f, fi) => (
                                          <div key={fi} style={{ fontSize: 11, color: T.red, lineHeight: 1.4 }}>
                                            Red flag: {f}
                                          </div>
                                        ))}
                                      </div>
                                    )}
                                    {it.feedback && (
                                      <div style={{ fontSize: 11, color: T.slate600, marginTop: 4, lineHeight: 1.5 }}>
                                        {it.feedback}
                                      </div>
                                    )}
                                  </div>
                                ))}
                              </>
                            ) : (
                              <div style={{ fontSize: 12, color: T.slate500 }}>No references back yet.</div>
                            )}
                            <div style={{ fontSize: 10, color: T.slate400, marginTop: 8 }}>
                              Comes from the hiring module. Ticks itself at {autoSum ? autoSum.minimum : 2} positive.
                            </div>
                          </div>
                        )}

                        {!collapsed && !locked && step.auto_source === "references" && plan.candidate_id && (
                          <div style={{ marginTop: 10 }}>
                            <ReferenceCalls candidateId={plan.candidate_id} embedded />
                          </div>
                        )}

                        {!collapsed && !locked && groups.length > 0 && (
                          <div style={{ marginTop: 8 }}>
                            {groups.filter(g => !g.altFor).map((g, gi) => (
                              <div key={gi} style={{ marginTop: gi === 0 ? 0 : 10 }}>
                                {(g.group || g.info.length > 0) && (
                                  <GroupHead
                                    label={g.group}
                                    info={g.info}
                                    extra={g.items.some(i => altFor.has(i)) ? altToggle : null}
                                    style={{ marginBottom: 4 }}
                                    labelStyle={{
                                      fontSize: 10, fontWeight: 700, color: T.slate500,
                                      textTransform: "uppercase", letterSpacing: 0.4,
                                    }}
                                    pathColor={T.teal} linkColor={T.blue}
                                  />
                                )}
                                <div style={{ display: "grid", gap: 5 }}>
                                  {g.items.flatMap(label => (altActive && altFor.has(label))
                                    ? altGroups.filter(a => a.altFor === label).flatMap(a => a.items)
                                    : [label]).map((label, ix) => {
                                    const sd = subsDone.includes(label);
                                    // A line that links to a site form ticks itself.
                                    const byForm = !!formIdOf(label);
                                    // leading spaces nest the line under the one above
                                    const { level, text: shown } = splitIndent(label);
                                    const instr = instructions[shown];
                                    const icon = icons[shown] || null;
                                    // The Orientation line: only the owner ticks it, from its pop-up or here.
                                    const isOrientationLine = instr?.kind === ORIENTATION_KIND;
                                    const lineLocked = isOrientationLine && !isOwner;
                                    return (
                                      <ItemInfo key={ix} lines={itemInfo[label] || []} pathColor={T.teal} linkColor={T.blue}>
                                      <div style={{ display: "flex", gap: 6, alignItems: "flex-start", minWidth: 0, paddingLeft: level * 18 }}>
                                      <button
                                        onClick={byForm || lineLocked ? undefined : () => onToggleSubstep(step, label)}
                                        title={byForm ? "Ticks itself when the form is done"
                                          : lineLocked ? "Peter checks this off at orientation" : undefined}
                                        style={{
                                          display: "flex", gap: 7, alignItems: "flex-start",
                                          background: "none", border: "none", padding: 0,
                                          cursor: byForm || lineLocked ? "default" : "pointer", textAlign: "left", flex: 1, minWidth: 0,
                                        }}
                                      >
                                        <span style={{
                                          width: 14, height: 14, borderRadius: 3, flexShrink: 0,
                                          marginTop: 2, boxSizing: "border-box",
                                          background: sd ? T.green : T.white,
                                          border: `1.5px solid ${sd ? T.green : T.slate300}`,
                                          display: "flex", alignItems: "center", justifyContent: "center",
                                        }}>
                                          {sd && <span style={{ color: T.white, fontSize: 9, lineHeight: 1 }}>✓</span>}
                                        </span>
                                        <span style={{
                                          fontSize: 12, lineHeight: 1.4,
                                          color: sd ? T.slate400 : T.slate700,
                                          textDecoration: sd ? "line-through" : "none",
                                        }}><LabelText text={shown} icon={icon} pathColor={sd ? T.slate400 : T.teal} linkColor={T.blue} /></span>
                                      </button>
                                      {instr && !isOrientationLine && (
                                        <InfoDot title="Instructions" onClick={() => setOpenInstr(instr)} />
                                      )}
                                      {isOrientationLine && isOwner && (
                                        <InfoDot title="Open orientation" onClick={() => setOrientation(instr)} />
                                      )}
                                      </div>
                                      </ItemInfo>
                                    );
                                  })}
                                </div>
                              </div>
                            ))}
                            <div style={{ fontSize: 10, color: gated ? T.amber : T.slate400, marginTop: 6 }}>
                              {sp.done}/{sp.total} done
                              {gated ? " — tick them all to finish this step" : ""}
                            </div>
                          </div>
                        )}

                        {isExpanded && (
                          <div style={{ marginTop: 8, padding: "8px 10px", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 6 }}>
                            {step.source_manual_id && (
                              <div style={{ fontSize: 11, color: T.slate500, marginBottom: 8 }}>
                                Reference: <a
                                  href={`/admin#${step.source_anchor || ""}`}
                                  style={{ color: T.blue, textDecoration: "underline" }}
                                  onClick={(e) => e.stopPropagation()}
                                >admin manual</a>
                              </div>
                            )}

                            {isEditingThis ? (
                              <div>
                                <textarea
                                  value={editingNote.text}
                                  onChange={(e) => setEditingNote({ ...editingNote, text: e.target.value })}
                                  placeholder="Notes on this step…"
                                  rows={3}
                                  style={{ ...inputBase, resize: "vertical", fontFamily: "inherit" }}
                                  autoFocus
                                />
                                <div style={{ marginTop: 6, display: "flex", gap: 6 }}>
                                  <Button variant="primary" onClick={() => handleSaveNote(step.id)} disabled={isSaving}>Save</Button>
                                  <Button variant="secondary" onClick={() => setEditingNote(null)}>Cancel</Button>
                                </div>
                              </div>
                            ) : (
                              <div>
                                {step.notes && (
                                  <div style={{ fontSize: 12, color: T.slate700, marginBottom: 6, whiteSpace: "pre-wrap" }}>
                                    {step.notes}
                                  </div>
                                )}
                                <button
                                  onClick={() => setEditingNote({ stepId: step.id, text: step.notes || "" })}
                                  style={{ fontSize: 11, color: T.blue, background: "none", border: "none", padding: 0, cursor: "pointer", fontWeight: 500 }}
                                >
                                  {step.notes ? "Edit note" : "Add note"}
                                </button>
                              </div>
                            )}
                          </div>
                        )}

                        {collapsed && (
                          <button
                            onClick={() => setExpandedStep(step.id)}
                            style={{ fontSize: 10, color: T.slate400, marginTop: 4, background: "none", border: "none", padding: 0, cursor: "pointer", textAlign: "left" }}
                          >
                            Completed {fmtDate(step.completed_at.slice(0, 10))} · <span style={{ color: T.blue }}>Show</span>
                          </button>
                        )}
                        {done && isExpanded && (
                          <button
                            onClick={() => setExpandedStep(null)}
                            style={{ fontSize: 10, color: T.blue, marginTop: 6, background: "none", border: "none", padding: 0, cursor: "pointer" }}
                          >Hide</button>
                        )}
                      </div>
                    </div>
                  </div>
                );
            };

            // Goals and the like sit across the top of the card.
            const banners = phaseSteps.filter(s => s.full_width);
            const rest = phaseSteps.filter(s => !s.full_width);
            const bannerRow = banners.length > 0 && (
              <div style={bannerStyle}>{banners.map(renderStep)}</div>
            );
            const cols = trackColumns(rest);
            const gridStyle = {
              display: "grid",
              gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))",
              gap: cols ? 12 : 10, alignItems: cols ? "stretch" : "start",
            };
            if (!cols) return <>{bannerRow}<div style={gridStyle}>{rest.map(renderStep)}</div></>;
            return (
              <>{bannerRow}
              <div style={gridStyle}>
                {cols.map((c, ci) => (
                  <div key={c.name || "_"} style={columnStyle(ci)}>
                    {c.name && <div style={trackHeadStyle}>{c.name}</div>}
                    {c.steps.map(renderStep)}
                  </div>
                ))}
              </div>
              </>
            );
            })()}
          </Card>
        );
      })}
    </div>
  );
}

// ─── create-plan modal ──────────────────────────────
function CreatePlanModal({ team, candidates, existingPlans, onClose, onCreated }) {
  const [subjectKind, setSubjectKind] = useState("team");   // "team" | "candidate"
  const [teamMemberId, setTeamMemberId] = useState("");
  const [candidateId, setCandidateId] = useState("");
  const [candRole, setCandRole] = useState("");             // Sales | Retention
  const [startDate, setStartDate] = useState(new Date().toISOString().slice(0, 10));
  const [notes, setNotes] = useState("");
  const [preview, setPreview] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const runningPlans = useMemo(
    () => (existingPlans || []).filter(p => p.status === "active" || p.status === "paused"),
    [existingPlans]
  );

  // Eligible: active, non-admin_backoffice, non-test, no existing active/paused plan
  const eligible = useMemo(() => {
    const busyIds = new Set(runningPlans.map(p => p.team_member_id));
    return team
      .filter(t => t.is_active && !t.is_admin_backoffice && !t.is_test_user && !t.archived_at && !busyIds.has(t.id))
      .sort((a, b) => (a.first_name || "").localeCompare(b.first_name || ""));
  }, [team, runningPlans]);

  // A plan can start the moment an offer goes out, before they are on the team.
  const eligibleCandidates = useMemo(() => {
    const busyIds = new Set(runningPlans.map(p => p.candidate_id));
    return (candidates || [])
      .filter(c => !busyIds.has(c.id))
      .sort((a, b) => (a.first_name || a.candidate_name || "").localeCompare(b.first_name || b.candidate_name || ""));
  }, [candidates, runningPlans]);

  // Preview: query which templates would apply, without actually creating
  useEffect(() => {
    let member = null;
    if (subjectKind === "team") {
      if (!teamMemberId) { setPreview(null); return; }
      member = team.find(t => t.id === teamMemberId) || null;
    } else {
      if (!candidateId) { setPreview(null); return; }
      member = { role: null, role_category: candRole || null, role_level: null };
    }
    if (!member) { setPreview(null); return; }

    let cancelled = false;
    supabase
      .from("onboarding_step_templates")
      .select("id, phase, category, is_required, applies_to_roles, applies_to_role_categories, applies_to_role_levels")
      .eq("agency_id", AGENCY_ID)
      .eq("is_active", true)
      .then(({ data, error: err }) => {
        if (cancelled) return;
        if (err) { setPreview({ error: err.message }); return; }
        const matching = (data || []).filter(t => {
          const roleOk = !t.applies_to_roles || t.applies_to_roles.includes(member.role);
          const catOk = !t.applies_to_role_categories || t.applies_to_role_categories.includes(member.role_category);
          const lvlOk = !t.applies_to_role_levels || t.applies_to_role_levels.includes(member.role_level);
          return roleOk && catOk && lvlOk;
        });
        const byPhase = {};
        matching.forEach(m => { byPhase[m.phase] = (byPhase[m.phase] || 0) + 1; });
        setPreview({
          total: matching.length,
          required: matching.filter(m => m.is_required).length,
          byPhase,
        });
      });

    return () => { cancelled = true; };
  }, [subjectKind, teamMemberId, candidateId, candRole, team]);

  const submit = async () => {
    setError("");
    if (subjectKind === "team" && !teamMemberId) { setError("Pick a teammate."); return; }
    if (subjectKind === "candidate" && !candidateId) { setError("Pick a candidate."); return; }
    if (!startDate) { setError("Pick a start date."); return; }
    setBusy(true);
    try {
      const { data, error: err } = await supabase.rpc("create_onboarding_plan", {
        p_team_member_id: subjectKind === "team" ? teamMemberId : null,
        p_candidate_id: subjectKind === "candidate" ? candidateId : null,
        p_role_category: subjectKind === "candidate" ? (candRole || null) : null,
        p_start_date: startDate,
        p_notes: notes || null,
      });
      if (err) throw err;
      onCreated(data);
    } catch (e) {
      setError(e.message || "Failed to create plan.");
      setBusy(false);
    }
  };

  return (
    <div style={{
      position: "fixed", inset: 0, background: "rgba(0,0,0,0.35)",
      display: "flex", alignItems: "center", justifyContent: "center",
      padding: 16, zIndex: 1000,
    }} onClick={onClose}>
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: T.white, borderRadius: 12, padding: 22,
          boxSizing: "border-box",
          maxWidth: 480, width: "100%", maxHeight: "90vh",
          overflowY: "auto", overflowX: "hidden",
          boxShadow: "0 20px 50px rgba(0,0,0,0.25)",
        }}
      >
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>Create onboarding plan</div>
        <div style={{ fontSize: 12, color: T.slate500, marginBottom: 18 }}>
          Pulls the steps that match the role. Start it at offer and the licensing and pre-start
          milestones are already there.
        </div>

        <div style={{ marginBottom: 14 }}>
          <label style={fieldLabel}>Who is this for</label>
          <div style={{ display: "flex", gap: 6 }}>
            {[
              { id: "team", label: "On the team" },
              { id: "candidate", label: "Still a candidate" },
            ].map(o => {
              const on = subjectKind === o.id;
              return (
                <button
                  key={o.id}
                  onClick={() => setSubjectKind(o.id)}
                  style={{
                    flex: 1, padding: "8px 10px", fontSize: 12, fontWeight: 600,
                    color: on ? T.white : T.slate700,
                    background: on ? T.blue : T.white,
                    border: `1px solid ${on ? T.blue : T.slate300}`,
                    borderRadius: 8, cursor: "pointer", boxSizing: "border-box",
                  }}
                >{o.label}</button>
              );
            })}
          </div>
        </div>

        {subjectKind === "team" ? (
          <div style={{ marginBottom: 14 }}>
            <label style={fieldLabel}>Teammate</label>
            <select value={teamMemberId} onChange={(e) => setTeamMemberId(e.target.value)} style={inputBase}>
              <option value="">Pick someone…</option>
              {eligible.map(t => (
                <option key={t.id} value={t.id}>
                  {memberName(t)} — {t.role || "no role"}
                  {t.role_category ? ` (${t.role_category})` : ""}
                </option>
              ))}
            </select>
            {eligible.length === 0 && (
              <div style={{ fontSize: 11, color: T.amber, marginTop: 6 }}>
                No eligible teammates. Everyone active either has a plan already or is admin/back-office.
              </div>
            )}
          </div>
        ) : (
          <div style={{ marginBottom: 14 }}>
            <label style={fieldLabel}>Candidate</label>
            <select value={candidateId} onChange={(e) => setCandidateId(e.target.value)} style={inputBase}>
              <option value="">Pick someone…</option>
              {eligibleCandidates.map(c => (
                <option key={c.id} value={c.id}>
                  {`${c.first_name || ""} ${c.last_name || ""}`.trim() || c.candidate_name}
                  {c.offer_job_title ? ` — ${c.offer_job_title}` : ` — ${c.status}`}
                </option>
              ))}
            </select>
            {eligibleCandidates.length === 0 && (
              <div style={{ fontSize: 11, color: T.amber, marginTop: 6 }}>
                No candidates at interview or later without a plan.
              </div>
            )}
            <div style={{ marginTop: 10 }}>
              <label style={fieldLabel}>Which side</label>
              <select value={candRole} onChange={(e) => setCandRole(e.target.value)} style={inputBase}>
                <option value="">Not decided yet — shared steps only</option>
                <option value="Sales">Sales</option>
                <option value="Retention">Retention</option>
              </select>
            </div>
          </div>
        )}

        <div style={{ marginBottom: 14 }}>
          <label style={fieldLabel}>Start date</label>
          <input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} style={inputBase} />
        </div>

        <div style={{ marginBottom: 14 }}>
          <label style={fieldLabel}>Plan notes (optional)</label>
          <textarea
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            rows={2}
            placeholder="Anything specific to this hire's ramp…"
            style={{ ...inputBase, resize: "vertical", fontFamily: "inherit" }}
          />
        </div>

        {/* Preview */}
        {preview && !preview.error && (
          <div style={{ padding: "10px 12px", background: T.slate50, borderRadius: 6, marginBottom: 14 }}>
            <div style={{ fontSize: 11, color: T.slate700, marginBottom: 6, fontWeight: 600 }}>
              {preview.total} steps will be compiled ({preview.required} required)
            </div>
            <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
              {Object.entries(preview.byPhase).sort((a, b) => a[0] - b[0]).map(([ph, n]) => (
                <span key={ph} style={{ fontSize: 10, color: T.slate500 }}>
                  Phase {ph}: <strong style={{ color: T.slate800 }}>{n}</strong>
                </span>
              ))}
            </div>
          </div>
        )}
        {preview?.error && (
          <div style={{ padding: "8px 10px", background: T.redLt, color: T.red, borderRadius: 6, marginBottom: 14, fontSize: 12 }}>
            {preview.error}
          </div>
        )}

        {error && (
          <div style={{ padding: "8px 10px", background: T.redLt, color: T.red, borderRadius: 6, marginBottom: 14, fontSize: 12 }}>
            {error}
          </div>
        )}

        <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
          <Button variant="secondary" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" onClick={submit} disabled={busy || (subjectKind === "team" ? !teamMemberId : !candidateId)}>
            {busy ? "Creating…" : "Create plan"}
          </Button>
        </div>
      </div>
    </div>
  );
}

// ─── plan list card ────────────────────────────────
function PlanListCard({ plan, steps, subjectName, isCandidate, onOpen }) {
  const p = progress(steps);
  const statusCol = STATUS_COLORS[plan.status] || STATUS_COLORS.active;
  return (
    <a
      href={`/development?plan=${plan.id}`}
      onClick={(e) => {
        if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        e.preventDefault();
        onOpen(plan.id);
      }}
      style={{ textDecoration: "none", color: "inherit", display: "block", marginBottom: 10 }}
    >
      <Card style={{ cursor: "pointer" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12 }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
              <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{subjectName}</div>
              <Pill fg={statusCol.fg} bg={statusCol.bg}>{statusCol.label}</Pill>
              {isCandidate && <Pill fg={T.purple} bg={T.purpleLt}>Offer stage</Pill>}
            </div>
            <div style={{ fontSize: 11, color: T.slate500 }}>
              {plan.role_snapshot || "—"}
              {plan.role_category_snapshot ? ` · ${plan.role_category_snapshot}` : ""}
              {" · "}Started {fmtDate(plan.start_date)}
              {" · Day "}{daysBetween(plan.start_date)}
            </div>
          </div>
          <div style={{ textAlign: "right", flexShrink: 0 }}>
            <div style={{ fontSize: 18, fontWeight: 700, color: p.pct === 100 ? T.green : T.amber }}>{p.pct}%</div>
            <div style={{ fontSize: 10, color: T.slate500 }}>{p.done}/{p.total}</div>
          </div>
        </div>
        <div style={{ marginTop: 10, height: 4, background: T.slate100, borderRadius: 2, overflow: "hidden" }}>
          <div style={{ height: "100%", width: `${p.pct}%`, background: p.pct === 100 ? T.green : T.blue, transition: "width 0.4s" }} />
        </div>
      </Card>
    </a>
  );
}

// ─── left sidebar (admin) ───────────────────────────
// New plan on top, then every plan, then the template. Peter 2026-09-21.
function OnboardingSidebar({ plans, activePlanId, onTemplate, onNew, subjectName, progressFor, onSelectPlan, onSelectTemplate, isPhone }) {
  const divider = <div style={{ height: 1, background: T.slate200, margin: "8px 0" }} />;
  const itemStyle = (on) => ({
    display: "block", width: "100%", boxSizing: "border-box",
    padding: "7px 10px", borderRadius: 6, fontSize: 13,
    fontWeight: on ? 700 : 500,
    color: on ? T.blue : T.slate700,
    background: on ? T.blueLt : "transparent",
    textDecoration: "none", ...wrapLongText,
  });
  return (
    <nav style={{
      flex: isPhone ? "1 1 100%" : "0 0 190px", minWidth: 0,
      background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12,
      padding: 8, boxSizing: "border-box",
    }}>
      <Button variant="primary" onClick={onNew} style={{ width: "100%" }}>+ New plan</Button>
      {plans.length > 0 && divider}
      {plans.map(pl => {
        const on = pl.id === activePlanId;
        const pct = progressFor(pl.id);
        return (
          <TabLink
            key={pl.id}
            href={hrefWithParams([["subtab", "plans", "plans"], ["plan", pl.id, null]])}
            onSelect={() => onSelectPlan(pl.id)}
            style={itemStyle(on)}
          >
            {subjectName(pl)}
            <span style={{ display: "block", fontSize: 10, fontWeight: 500, color: T.slate400, marginTop: 1 }}>
              {pl.status === "active" ? `${pct}%` : (STATUS_COLORS[pl.status]?.label || pl.status)}
            </span>
          </TabLink>
        );
      })}
      {divider}
      <TabLink
        href={hrefWithParams([["subtab", "template", "plans"], ["plan", null, null]])}
        onSelect={onSelectTemplate}
        style={itemStyle(onTemplate)}
      >Template</TabLink>
    </nav>
  );
}

// ─── main component ────────────────────────────────
export default function Onboarding({ userRole, userId }) {
  const isAdmin = ADMIN_ROLES.includes(userRole);
  // Only the owner opens the Orientation pop-up and checks Orientation off.
  const isOwner = userRole === "owner";
  const { loading, error, plans, steps, team, phases, candidates, myTeamMemberId, planNames, instructions, icons, reload } = useOnboardingData(userId, isAdmin);

  // URL-persisted so refresh keeps the same plan open. Replaces the prior
  // useState + manual ?plan= useEffect pair — useTabParam handles both the
  // read on mount and the write on every setSelectedPlanId call.
  const [selectedPlanId, setSelectedPlanId] = useTabParam("plan", null);
  const [tab, setTab, tabHref] = useTabParam("subtab", "plans", ["plans", "template"]);
  const [showCreate, setShowCreate] = useState(false);
  const [actionError, setActionError] = useState("");
  const vp = useViewport();

  const teamById = useMemo(() => {
    const m = new Map();
    team.forEach(t => m.set(t.id, t));
    return m;
  }, [team]);

  const candidateById = useMemo(() => {
    const m = new Map();
    (candidates || []).forEach(c => m.set(c.id, c));
    return m;
  }, [candidates]);

  const phaseMeta = useCallback((phase) => {
    const row = (phases || []).find(p => p.phase === phase);
    if (row) return {
      name: row.name, blurb: row.blurb || "", stage: row.stage,
      weeksLong: row.weeks_long || 0, weekTitles: row.week_titles || {},
    };
    const fb = PHASE_LABELS[phase];
    return fb ? { ...fb, stage: null } : { name: `Phase ${phase}`, blurb: "", stage: null };
  }, [phases]);

  // "Alvi" / "Peter" / whoever owns a step that is not the new hire's own.
  const ownerName = useCallback((step) => {
    const plus = step.assign_role_category ? ` + ${step.assign_role_category}` : "";
    if (step.assigned_to) {
      const t = (team || []).find(x => x.id === step.assigned_to);
      if (t) return memberName(t) + plus;
    }
    if (plus) return step.assign_role_category;
    if (step.owner_kind === "agent") return "Peter";
    if (step.owner_kind === "team") return "Everyone";
    if (step.owner_kind === "admin") return "Admin";
    return "New hire";
  }, [team]);

  const candidateName = useCallback((c) => {
    if (!c) return "Candidate";
    const n = `${c.first_name || ""} ${c.last_name || ""}`.trim();
    return n || c.candidate_name || "Candidate";
  }, []);

  const subjectName = useCallback((plan) => {
    if (plan.team_member_id && teamById.get(plan.team_member_id)) return memberName(teamById.get(plan.team_member_id));
    const c = candidateById.get(plan.candidate_id);
    if (c) return candidateName(c);
    return (planNames && planNames[plan.id]) || "New hire";
  }, [teamById, candidateById, candidateName, planNames]);

  const stepsByPlan = useMemo(() => {
    const m = new Map();
    steps.forEach(s => {
      if (!m.has(s.plan_id)) m.set(s.plan_id, []);
      m.get(s.plan_id).push(s);
    });
    return m;
  }, [steps]);

  // ─── actions ──────────────────────────────────
  const handleToggleStep = async (step) => {
    setActionError("");
    if (step.auto_source) {
      setActionError("That step fills itself in from the rest of Newtworks. It cannot be ticked by hand.");
      return;
    }
    if (!step.completed_at) {
      const sp = subProgress(step.substeps, step.substeps_done);
      if (sp.total && !sp.complete) {
        setActionError(`Finish all ${sp.total} sub-items first.`);
        return;
      }
    }
    const { error: err } = await setStepDone(step.id, !step.completed_at, userId);
    if (err) { setActionError(err.message); return; }
    await reload();
  };

  // Ticking the last sub-item completes the step; unticking any re-opens it.
  const handleToggleSubstep = async (step, label) => {
    if (formIdOf(label)) return; // follows the form, not a click
    setActionError("");
    const cur = Array.isArray(step.substeps_done) ? step.substeps_done : [];
    const { error: err } = await setSubstepDone(step, label, !cur.includes(label), userId);
    if (err) { setActionError(err.message); return; }
    await reload();
  };

  const handleUpdateStepNotes = async (stepId, notesText) => {
    setActionError("");
    const { error: err } = await supabase.from("team_onboarding_steps")
      .update({ notes: notesText || null })
      .eq("id", stepId);
    if (err) { setActionError(err.message); return; }
    await reload();
  };

  const handleDeletePlan = async (planId) => {
    if (!confirm("Delete this onboarding plan and all its steps? Cannot be undone.")) return;
    setActionError("");
    const { error: err } = await supabase.from("team_onboarding_plans").delete().eq("id", planId);
    if (err) { setActionError(err.message); return; }
    setSelectedPlanId(null);
    await reload();
  };

  const handleChangeStatus = async (planId, newStatus) => {
    setActionError("");
    const { error: err } = await supabase.from("team_onboarding_plans")
      .update({ status: newStatus })
      .eq("id", planId);
    if (err) { setActionError(err.message); return; }
    await reload();
  };

  const handleCreated = async (newPlanId) => {
    setShowCreate(false);
    await reload();
    setSelectedPlanId(newPlanId);
  };

  // ─── render ────────────────────────────────────
  if (loading) {
    return <div style={{ padding: 40, textAlign: "center", color: T.slate500, fontSize: 13 }}>Loading onboarding…</div>;
  }
  if (error) {
    return <div style={{ padding: 20 }}>
      <Card><div style={{ color: T.red, fontSize: 13 }}>Error: {error}</div></Card>
    </div>;
  }

  // Team-tier view. The database already hands back only the plans and
  // cards this person may see: their own plan from Day 1, plus any card
  // assigned to them on someone else's plan.
  if (!isAdmin) {
    const open = plans.filter(p => p.status === "active" || p.status === "paused");
    const list = open.length ? open : plans;
    if (list.length === 0) {
      return (
        <div style={{ padding: 20 }}>
          <Card>
            <div style={{ fontSize: 14, color: T.slate800, marginBottom: 6, fontWeight: 600 }}>Nothing here for you yet</div>
            <div style={{ fontSize: 12, color: T.slate500 }}>
              Your onboarding plan, and any onboarding card assigned to you, will show up here.
            </div>
          </Card>
        </div>
      );
    }
    const chosen = list.find(p => p.id === selectedPlanId) || (list.length === 1 ? list[0] : null);
    if (chosen) {
      return (
        <div style={{ padding: 20 }}>
          <FormPopupProvider teamId={chosen.team_member_id || null} onClosed={reload}>
          <PlanDetail
            plan={chosen}
            steps={stepsByPlan.get(chosen.id) || []}
            subjectName={subjectName(chosen)}
            isCandidate={!chosen.team_member_id}
            phaseMeta={phaseMeta}
            ownerName={ownerName}
            instructions={instructions}
            icons={icons}
            onBack={() => setSelectedPlanId(null)}
            onToggleStep={handleToggleStep}
            onToggleSubstep={handleToggleSubstep}
            onUpdateStepNotes={handleUpdateStepNotes}
            onDeletePlan={handleDeletePlan}
            onChangeStatus={handleChangeStatus}
            isAdmin={false}
            isOwner={isOwner}
            userId={userId}
            onReload={reload}
            showBack={list.length > 1}
          />
          </FormPopupProvider>
          {actionError && <Card style={{ marginTop: 10, background: T.redLt }}><div style={{ color: T.red, fontSize: 12 }}>{actionError}</div></Card>}
        </div>
      );
    }
    return (
      <div style={{ padding: 20 }}>
        {list.map(plan => (
          <PlanListCard
            key={plan.id}
            plan={plan}
            steps={stepsByPlan.get(plan.id) || []}
            subjectName={subjectName(plan)}
            isCandidate={!plan.team_member_id}
            onOpen={setSelectedPlanId}
          />
        ))}
      </div>
    );
  }

  // Admin view. Left sidebar: New plan, every plan, Template.
  const openPlans = plans.filter(p => p.status === "active" || p.status === "paused");
  const selectedPlan = plans.find(p => p.id === selectedPlanId)
    || (tab === "plans" ? (openPlans[0] || plans[0] || null) : null);
  const statusRank = { active: 0, paused: 1, completed: 2, archived: 3 };
  const sidebarPlans = [...plans].sort((a, b) => (statusRank[a.status] ?? 9) - (statusRank[b.status] ?? 9));

  return (
    <div style={{
      padding: vp.isPhone ? 12 : 20, display: "flex", gap: 16, alignItems: "flex-start",
      flexWrap: vp.isPhone ? "wrap" : "nowrap", boxSizing: "border-box",
    }}>
      <OnboardingSidebar
        plans={sidebarPlans}
        activePlanId={tab === "plans" ? selectedPlan?.id : null}
        onTemplate={tab === "template"}
        onNew={() => setShowCreate(true)}
        subjectName={subjectName}
        progressFor={(id) => progress(stepsByPlan.get(id) || []).pct}
        onSelectPlan={(id) => { setTab("plans"); setSelectedPlanId(id); }}
        onSelectTemplate={() => { setSelectedPlanId(null); setTab("template"); }}
        isPhone={vp.isPhone}
      />

      <div style={{ flex: "1 1 0", minWidth: 0 }}>
        {actionError && <Card style={{ marginBottom: 12, background: T.redLt }}><div style={{ color: T.red, fontSize: 12 }}>{actionError}</div></Card>}

        {tab === "template" ? (
          <FormPopupProvider>
          <OnboardingTemplateEditor
            phaseMeta={phaseMeta}
            ownerName={ownerName}
            team={team}
            phases={phases}
            canEdit={isAdmin}
            onPhasesChanged={reload}
            isOwner={isOwner}
            userId={userId}
            onReload={reload}
            instructions={instructions}
          />
          </FormPopupProvider>
        ) : selectedPlan ? (
          <FormPopupProvider teamId={selectedPlan.team_member_id || null} onClosed={reload}>
          <PlanDetail
            plan={selectedPlan}
            steps={stepsByPlan.get(selectedPlan.id) || []}
            subjectName={subjectName(selectedPlan)}
            isCandidate={!selectedPlan.team_member_id}
            phaseMeta={phaseMeta}
            ownerName={ownerName}
            instructions={instructions}
            icons={icons}
            onBack={() => setSelectedPlanId(null)}
            onToggleStep={handleToggleStep}
            onToggleSubstep={handleToggleSubstep}
            onUpdateStepNotes={handleUpdateStepNotes}
            onDeletePlan={handleDeletePlan}
            onChangeStatus={handleChangeStatus}
            isAdmin={true}
            isOwner={isOwner}
            userId={userId}
            onReload={reload}
            showBack={false}
          />
          </FormPopupProvider>
        ) : (
          <Card>
            <div style={{ fontSize: 14, color: T.slate800, marginBottom: 6, fontWeight: 600 }}>No onboarding plans yet</div>
            <div style={{ fontSize: 12, color: T.slate500 }}>
              Start one with New plan. The steps are pulled from the template for their role.
            </div>
          </Card>
        )}
      </div>

      {showCreate && (
        <CreatePlanModal
          team={team}
          candidates={candidates}
          existingPlans={plans}
          onClose={() => setShowCreate(false)}
          onCreated={handleCreated}
        />
      )}
    </div>
  );
}
