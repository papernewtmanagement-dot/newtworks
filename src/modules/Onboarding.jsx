// =========================================================================
// Onboarding.jsx
// =========================================================================
// Team-visible module: teammates see their own plan; admin (owner/manager)
// sees all plans, can create new plans and delete/complete plans.
//
// Data: team_onboarding_plans + team_onboarding_steps.
// Plan creation compiles from onboarding_step_templates via RPC
// create_onboarding_plan_from_templates(team_member_id, start_date,
// target_end_date, notes). Templates are snapshotted at create-time into
// team_onboarding_steps — later template edits do NOT retro-mutate a
// running plan.
//
// RLS on the underlying tables enforces admin RW / team-tier read-own +
// update-own-steps. This UI mirrors that scoping.
// =========================================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { TabLink, useTabParam } from "../lib/routing.jsx";

// ─── constants ─────────────────────────────────────
const ADMIN_ROLES = ["owner", "manager"];

// Week bands match the ramp table the agency has always run on: 1-2, 3-4,
// 5-8, 9-13, 14+. The earlier labels here (Week 1 / Weeks 2-3 / Month 2 /
// Month 3) did not line up with the steps sitting in each phase.
// Fallback only. The real phase list lives in onboarding_phases so milestones
// can be added without a deploy.
const PHASE_LABELS = {
  10: { name: "On offer",                    blurb: "Offer out. Licensing starts, prior appointments end." },
  15: { name: "References and background",   blurb: "Runs as soon as they reply to the offer email." },
  20: { name: "Two weeks before start",      blurb: "System access, equipment, cards, nameplate." },
  25: { name: "Once they have an alias",     blurb: "Softphone and logins." },
  30: { name: "Once they have an extension", blurb: "Team list and call flow." },
  35: { name: "Workspace ready",             blurb: "Desk, hardware, keys. Confirmed working before Day 1." },
  40: { name: "Friday before start",         blurb: "Welcome call, schedule, printed packet." },
  50: { name: "Day 1",                       blurb: "Tech setup, paperwork, keys, first walkthrough." },
  55: { name: "Weeks 1-2",                   blurb: "Orientation, courses, shadowing. No production target." },
  60: { name: "Weeks 3-4",                   blurb: "First independent work, daily wrap-ups, weekly 1:1s." },
  65: { name: "Weeks 5-8",                   blurb: "Review cadence begins, Life pipeline starts, half shadow." },
  70: { name: "Weeks 9-13",                  blurb: "Full quote share, weekly claims rhythm, cross-training." },
  75: { name: "Week 14+",                    blurb: "Fully independent. Champions Circle pace, monthly audit rhythm." },
};

const STAGE_LABELS = {
  offer:     { label: "Offer stage", fg: T.purple, bg: T.purpleLt },
  pre_start: { label: "Before Day 1", fg: T.gold,  bg: T.goldLt },
  ramp:      { label: "On the job",   fg: T.blue,  bg: T.blueLt },
};

// Sub-items arrive either as a flat list of strings or as groups the old paper
// checklists used ({ group, items }). Normalize both to groups.
function subGroups(substeps) {
  if (!Array.isArray(substeps)) return [];
  const out = [];
  let flat = null;
  substeps.forEach(s => {
    if (s && typeof s === "object" && Array.isArray(s.items)) {
      out.push({ group: s.group || null, items: s.items.filter(x => typeof x === "string") });
    } else if (typeof s === "string") {
      if (!flat) { flat = { group: null, items: [] }; out.push(flat); }
      flat.items.push(s);
    }
  });
  return out.filter(g => g.items.length);
}
function subAll(substeps) {
  return subGroups(substeps).reduce((acc, g) => acc.concat(g.items), []);
}

// A phase with more than one track draws one column per track — the two
// offer-stage columns both have to finish before the next milestone opens.
function trackColumns(steps) {
  const names = [];
  steps.forEach(s => {
    const t = s.track || null;
    if (!names.includes(t)) names.push(t);
  });
  if (names.length <= 1) return null;
  return names.map(n => ({ name: n, steps: steps.filter(s => (s.track || null) === n) }));
}

const trackHeadStyle = {
  fontSize: 11, fontWeight: 700, color: T.slate600,
  textTransform: "uppercase", letterSpacing: 0.5, marginBottom: 2,
};

const CATEGORY_COLORS = {
  licensing:      { fg: T.green,  bg: T.greenLt,  label: "Licensing" },
  documents:      { fg: T.blue,   bg: T.blueLt,   label: "Documents" },
  compliance:     { fg: T.red,    bg: T.redLt,    label: "Compliance" },
  systems:        { fg: T.teal,   bg: T.tealLt,   label: "Systems" },
  training:       { fg: T.purple, bg: T.purpleLt, label: "Training" },
  physical_setup: { fg: T.gold,   bg: T.goldLt,   label: "Physical setup" },
  role_specific:  { fg: T.pink,   bg: T.pinkLt,   label: "Role-specific" },
};

const STATUS_COLORS = {
  active:    { fg: T.green,   bg: T.greenLt, label: "Active" },
  paused:    { fg: T.amber,   bg: T.amberLt, label: "Paused" },
  completed: { fg: T.slate600, bg: T.slate100, label: "Completed" },
  archived:  { fg: T.slate500, bg: T.slate100, label: "Archived" },
};

// ─── shared UI primitives ───────────────────────────────
const Card = ({ children, style = {} }) => (
  <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: "16px 18px", ...style }}>
    {children}
  </div>
);

const Pill = ({ children, fg = T.slate700, bg = T.slate100, style = {} }) => (
  <span style={{
    display: "inline-block", fontSize: 10, fontWeight: 600,
    color: fg, background: bg,
    padding: "3px 8px", borderRadius: 4, letterSpacing: 0.3,
    textTransform: "uppercase", ...style,
  }}>{children}</span>
);

const Button = ({ children, onClick, variant = "primary", disabled = false, style = {} }) => {
  const styles = {
    primary:   { bg: T.blue,    fg: T.white,    border: T.blue },
    secondary: { bg: T.white,   fg: T.slate800, border: T.slate300 },
    danger:    { bg: T.white,   fg: T.red,      border: T.red },
    ghost:     { bg: "transparent", fg: T.slate600, border: "transparent" },
  }[variant] || {};
  return (
    <button
      onClick={onClick} disabled={disabled}
      style={{
        padding: "8px 14px", fontSize: 12, fontWeight: 600,
        color: styles.fg, background: styles.bg,
        border: `1px solid ${styles.border}`, borderRadius: 8,
        cursor: disabled ? "not-allowed" : "pointer",
        opacity: disabled ? 0.55 : 1,
        transition: "all 0.12s",
        ...style,
      }}
    >{children}</button>
  );
};

const fieldLabel = {
  fontSize: 11, fontWeight: 600, color: T.slate700,
  textTransform: "uppercase", letterSpacing: 0.4,
  marginBottom: 6, display: "block",
};

const inputBase = {
  width: "100%", boxSizing: "border-box", padding: "9px 11px", fontSize: 13,
  color: T.slate900, background: T.white,
  border: `1px solid ${T.slate300}`, borderRadius: 8,
  outline: "none",
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
  });

  const load = useCallback(async () => {
    if (!supabase || !AGENCY_ID) {
      setState(s => ({ ...s, loading: false, error: "Supabase not configured." }));
      return;
    }
    try {
      const [plansRes, teamRes, phasesRes, candsRes] = await Promise.all([
        supabase.from("team_onboarding_plans")
          .select("id, agency_id, team_member_id, candidate_id, attached_at, role_snapshot, role_category_snapshot, role_level_snapshot, start_date, target_end_date, status, notes, created_by, created_at, updated_at")
          .eq("agency_id", AGENCY_ID)
          .order("created_at", { ascending: false }),
        supabase.from("team_directory")
          .select("id, first_name, last_name, nickname, role, role_category, role_level, category, is_active, is_admin_backoffice, is_test_user, archived_at, user_id, start_date")
          .eq("agency_id", AGENCY_ID),
        supabase.from("onboarding_phases")
          .select("phase, name, blurb, stage")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true)
          .order("phase", { ascending: true }),
        supabase.from("hiring_candidates")
          .select("id, candidate_name, first_name, last_name, status, offer_job_title, offer_role_key, offer_start_date")
          .eq("agency_id", AGENCY_ID)
          .in("status", ["reference_check", "offer"]),
      ]);

      const plans = plansRes.data || [];
      const team = teamRes.data || [];
      const phases = phasesRes.data || [];
      const candidates = candsRes.data || [];

      let steps = [];
      if (plans.length) {
        const planIds = plans.map(p => p.id);
        const stepsRes = await supabase.from("team_onboarding_steps")
          .select("id, plan_id, template_key, title, description, phase, category, source_manual_id, source_anchor, sort_order, is_required, completed_at, completed_by, notes, substeps, substeps_done, owner_kind, assigned_to, task_id, track, blocked_by")
          .in("plan_id", planIds)
          .order("phase", { ascending: true })
          .order("sort_order", { ascending: true });
        steps = stepsRes.data || [];
      }

      let myTeamMemberId = null;
      if (userId) {
        const mine = team.find(t => t.user_id === userId);
        myTeamMemberId = mine?.id || null;
      }

      setState({ loading: false, error: null, plans, steps, team, phases, candidates, myTeamMemberId });
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

function fmtDate(iso) {
  if (!iso) return "—";
  const d = new Date(iso + (iso.length === 10 ? "T00:00:00" : ""));
  if (isNaN(d)) return iso;
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
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
function PlanDetail({ plan, subjectName, isCandidate, steps, onBack, onToggleStep, onToggleSubstep, onUpdateStepNotes, onDeletePlan, onChangeStatus, isAdmin, phaseMeta, ownerName }) {
  const [expandedStep, setExpandedStep] = useState(null);
  const [editingNote, setEditingNote] = useState(null); // {stepId, text}
  const [savingId, setSavingId] = useState(null);
  const p = progress(steps);

  // Group by phase, then category
  const byPhase = useMemo(() => {
    const map = new Map();
    steps.forEach(s => {
      if (!map.has(s.phase)) map.set(s.phase, []);
      map.get(s.phase).push(s);
    });
    return [...map.entries()].sort((a, b) => a[0] - b[0]);
  }, [steps]);

  // template_key -> title, for every step in this plan that is not done yet.
  // Anything listing one of these as a blocker stays locked.
  const blockersOpen = useMemo(() => {
    const m = new Map();
    steps.forEach(s => { if (!s.completed_at && s.template_key) m.set(s.template_key, s.title); });
    return m;
  }, [steps]);

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
      <div style={{ marginBottom: 16 }}>
        <a
          href="/development"
          onClick={(e) => {
            if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
            e.preventDefault();
            onBack();
          }}
          style={{ fontSize: 12, color: T.slate500, textDecoration: "none", display: "inline-flex", alignItems: "center", gap: 4 }}
        >← All schedules</a>
      </div>

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
              {plan.target_end_date ? ` · Target ${fmtDate(plan.target_end_date)}` : ""}
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

      {/* Phases */}
      {byPhase.map(([phase, phaseSteps]) => {
        const meta = phaseMeta(phase);
        const phaseP = progress(phaseSteps);

        return (
          <Card key={phase} style={{ marginBottom: 12 }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 10, marginBottom: 12, flexWrap: "wrap" }}>
              <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{meta.name}</div>
                {meta.stage && STAGE_LABELS[meta.stage] && (
                  <Pill fg={STAGE_LABELS[meta.stage].fg} bg={STAGE_LABELS[meta.stage].bg}>
                    {STAGE_LABELS[meta.stage].label}
                  </Pill>
                )}
                <div style={{ fontSize: 11, color: T.slate500, flexBasis: "100%" }}>{meta.blurb}</div>
              </div>
              <div style={{ fontSize: 11, color: T.slate500 }}>{phaseP.done}/{phaseP.total}</div>
            </div>

            {(() => {
            const renderStep = (step) => {
                const cc = CATEGORY_COLORS[step.category] || { fg: T.slate600, bg: T.slate100, label: step.category || "Step" };
                const isExpanded = expandedStep === step.id;
                const isEditingThis = editingNote?.stepId === step.id;
                const isSaving = savingId === step.id;
                const groups = subGroups(step.substeps);
                const subs = subAll(step.substeps);
                const subsDone = Array.isArray(step.substeps_done) ? step.substeps_done : [];
                const done = !!step.completed_at;
                const waitingOn = (step.blocked_by || [])
                  .filter(k => blockersOpen.has(k))
                  .map(k => blockersOpen.get(k));
                const locked = !done && waitingOn.length > 0;

                return (
                  <div key={step.id} style={{
                    border: `1px solid ${locked ? T.slate100 : T.slate200}`, borderRadius: 8,
                    padding: "10px 12px", boxSizing: "border-box",
                    background: done ? T.slate50 : T.white,
                    opacity: locked ? 0.55 : 1,
                  }}>
                    <div style={{ display: "flex", alignItems: "flex-start", gap: 10 }}>
                      <button
                        onClick={() => { if (!locked) handleToggle(step); }}
                        disabled={isSaving || locked}
                        style={{
                          width: 20, height: 20, borderRadius: 4, flexShrink: 0, boxSizing: "border-box",
                          background: done ? T.green : T.white,
                          border: `1.5px solid ${done ? T.green : T.slate300}`,
                          cursor: locked ? "not-allowed" : (isSaving ? "wait" : "pointer"),
                          display: "flex", alignItems: "center", justifyContent: "center",
                          marginTop: 1,
                        }}
                        title={done ? "Mark incomplete" : "Mark complete"}
                      >
                        {done && <span style={{ color: T.white, fontSize: 11, lineHeight: 1 }}>✓</span>}
                      </button>

                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 8 }}>
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
                            {!step.is_required && (
                              <span style={{ marginLeft: 8, fontSize: 10, color: T.slate400, fontWeight: 500 }}>optional</span>
                            )}
                          </div>
                          <div style={{ display: "flex", gap: 4, flexShrink: 0, flexWrap: "wrap", justifyContent: "flex-end" }}>
                            {step.owner_kind !== "new_hire" && (
                              <Pill fg={T.purple} bg={T.purpleLt}>{ownerName(step)}</Pill>
                            )}
                            <Pill fg={cc.fg} bg={cc.bg}>{cc.label}</Pill>
                          </div>
                        </div>

                        {step.description && (
                          <div style={{ fontSize: 11, color: T.slate500, marginTop: 3, lineHeight: 1.45 }}>
                            {step.description}
                          </div>
                        )}

                        {locked && (
                          <div style={{ fontSize: 11, color: T.amber, marginTop: 4, fontWeight: 600 }}>
                            Waiting on: {waitingOn.join(", ")}
                          </div>
                        )}

                        {!locked && groups.length > 0 && (
                          <div style={{ marginTop: 8 }}>
                            {groups.map((g, gi) => (
                              <div key={gi} style={{ marginTop: gi === 0 ? 0 : 10 }}>
                                {g.group && (
                                  <div style={{
                                    fontSize: 10, fontWeight: 700, color: T.slate500,
                                    textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 4,
                                  }}>{g.group}</div>
                                )}
                                <div style={{ display: "grid", gap: 5 }}>
                                  {g.items.map((label, ix) => {
                                    const sd = subsDone.includes(label);
                                    return (
                                      <button
                                        key={ix}
                                        onClick={() => onToggleSubstep(step, label)}
                                        style={{
                                          display: "flex", gap: 7, alignItems: "flex-start",
                                          background: "none", border: "none", padding: 0,
                                          cursor: "pointer", textAlign: "left", width: "100%",
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
                                        }}>{label}</span>
                                      </button>
                                    );
                                  })}
                                </div>
                              </div>
                            ))}
                            <div style={{ fontSize: 10, color: T.slate400, marginTop: 6 }}>
                              {subsDone.length}/{subs.length} done
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

                        {done && !isExpanded && (
                          <div style={{ fontSize: 10, color: T.slate400, marginTop: 4 }}>
                            Completed {fmtDate(step.completed_at.slice(0, 10))}
                          </div>
                        )}
                      </div>
                    </div>
                  </div>
                );
            };

            const cols = trackColumns(phaseSteps);
            const gridStyle = {
              display: "grid",
              gridTemplateColumns: "repeat(auto-fit, minmax(300px, 1fr))",
              gap: cols ? 16 : 10, alignItems: "start",
            };
            if (!cols) return <div style={gridStyle}>{phaseSteps.map(renderStep)}</div>;
            return (
              <div style={gridStyle}>
                {cols.map(c => (
                  <div key={c.name || "_"} style={{ display: "grid", gap: 10, alignContent: "start" }}>
                    {c.name && <div style={trackHeadStyle}>{c.name}</div>}
                    {c.steps.map(renderStep)}
                  </div>
                ))}
              </div>
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
  const [targetEndDate, setTargetEndDate] = useState("");
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
        p_target_end_date: targetEndDate || null,
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

        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: 12, marginBottom: 14 }}>
          <div>
            <label style={fieldLabel}>Start date</label>
            <input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} style={inputBase} />
          </div>
          <div>
            <label style={fieldLabel}>Target end (optional)</label>
            <input type="date" value={targetEndDate} onChange={(e) => setTargetEndDate(e.target.value)} style={inputBase} />
          </div>
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
          <Button variant="primary" onClick={submit} disabled={busy || !teamMemberId}>
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

// ─── tabs + template library ────────────────────────
const TABS = [
  { id: "plans",    label: "Plans" },
  { id: "template", label: "Template" },
];

function ModuleHeader({ tab, tabHref, onSelectTab, action = null }) {
  return (
    <div style={{ marginBottom: 16 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 10 }}>
        <div>
          <div style={{ fontSize: 12, color: T.slate500 }}>
            {tab === "template"
              ? "The master step list every new plan is built from."
              : "Onboarding plans in progress for new team members."}
          </div>
        </div>
        {action}
      </div>
      <div style={{
        display: "flex", gap: 4, marginTop: 12, flexWrap: "wrap",
        borderBottom: `1px solid ${T.slate200}`,
      }}>
        {TABS.map(t => {
          const on = t.id === tab;
          return (
            <TabLink
              key={t.id}
              href={tabHref(t.id)}
              onSelect={() => onSelectTab(t.id)}
              style={{
                flexShrink: 0, padding: "8px 14px", fontSize: 13, fontWeight: 600,
                color: on ? T.blue : T.slate600,
                background: "transparent",
                borderBottom: `2px solid ${on ? T.blue : "transparent"}`,
                marginBottom: -1, textDecoration: "none",
              }}
            >{t.label}</TabLink>
          );
        })}
      </div>
    </div>
  );
}

function appliesToText(t) {
  const bits = [];
  if (t.applies_to_roles?.length) bits.push(t.applies_to_roles.join(", "));
  if (t.applies_to_role_categories?.length) bits.push(t.applies_to_role_categories.join(", "));
  if (t.applies_to_role_levels?.length) bits.push(t.applies_to_role_levels.join(", "));
  return bits.length ? bits.join(" · ") : "Everyone";
}

// Read-only view of onboarding_step_templates — the library each new plan is
// compiled from. Editing lives in the database for now; this tab is the place
// the template can actually be read without opening the create-plan popup.
function TemplateTab({ phaseMeta, ownerName }) {
  const [state, setState] = useState({ loading: true, error: null, rows: [] });

  useEffect(() => {
    let cancelled = false;
    if (!supabase || !AGENCY_ID) {
      setState({ loading: false, error: "Supabase not configured.", rows: [] });
      return;
    }
    supabase
      .from("onboarding_step_templates")
      .select("id, template_key, title, description, phase, category, applies_to_roles, applies_to_role_categories, applies_to_role_levels, is_required, sort_order, notes, substeps, owner_kind, assigned_to, track, blocked_by")
      .eq("agency_id", AGENCY_ID)
      .eq("is_active", true)
      .order("phase", { ascending: true })
      .order("sort_order", { ascending: true })
      .then(({ data, error: err }) => {
        if (cancelled) return;
        setState({ loading: false, error: err ? err.message : null, rows: data || [] });
      });
    return () => { cancelled = true; };
  }, []);

  if (state.loading) {
    return <div style={{ padding: 30, textAlign: "center", color: T.slate500, fontSize: 13 }}>Loading template…</div>;
  }
  if (state.error) {
    return <Card style={{ background: T.redLt }}><div style={{ color: T.red, fontSize: 12 }}>{state.error}</div></Card>;
  }
  if (!state.rows.length) {
    return (
      <Card>
        <div style={{ fontSize: 14, fontWeight: 600, color: T.slate800, marginBottom: 6 }}>No template steps yet</div>
        <div style={{ fontSize: 12, color: T.slate500 }}>Nothing is set up in the step library, so a new plan would come out empty.</div>
      </Card>
    );
  }

  const phases = [...new Set(state.rows.map(r => r.phase))].sort((a, b) => a - b);
  const titleByKey = new Map(state.rows.map(r => [r.template_key, r.title]));

  return (
    <div>
      <Card style={{ marginBottom: 14, background: T.blueLt, border: `1px solid ${T.blue}` }}>
        <div style={{ fontSize: 12, color: T.slate800, lineHeight: 1.55 }}>
          {state.rows.length} steps. Creating a plan copies the ones that match that person's role into their own
          checklist. Changing this list does not change plans that are already running.
        </div>
      </Card>
      {phases.map(ph => {
        const rows = state.rows.filter(r => r.phase === ph);
        const label = phaseMeta(ph);
        return (
          <Card key={ph} style={{ marginBottom: 12 }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 10, marginBottom: 10, flexWrap: "wrap" }}>
              <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{label.name}</div>
                {label.stage && STAGE_LABELS[label.stage] && (
                  <Pill fg={STAGE_LABELS[label.stage].fg} bg={STAGE_LABELS[label.stage].bg}>
                    {STAGE_LABELS[label.stage].label}
                  </Pill>
                )}
                {label.blurb && <div style={{ fontSize: 11, color: T.slate500, flexBasis: "100%" }}>{label.blurb}</div>}
              </div>
              <div style={{ fontSize: 11, color: T.slate500 }}>{rows.length} steps</div>
            </div>

            {(() => {
            const renderRow = (r) => {
                const cat = CATEGORY_COLORS[r.category] || { fg: T.slate700, bg: T.slate100, label: r.category || "Step" };
                const groups = subGroups(r.substeps);
                const after = (r.blocked_by || []).map(k => titleByKey.get(k) || k);
                return (
                  <div key={r.id} style={{
                    border: `1px solid ${T.slate200}`, borderRadius: 8,
                    padding: "10px 12px", boxSizing: "border-box",
                  }}>
                    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 8 }}>
                      <div style={{ fontSize: 13, fontWeight: 600, color: T.slate900, lineHeight: 1.4 }}>
                        {r.title}
                        {!r.is_required && (
                          <span style={{ marginLeft: 8, fontSize: 10, color: T.slate400, fontWeight: 500 }}>optional</span>
                        )}
                      </div>
                      <div style={{ display: "flex", gap: 4, flexShrink: 0, flexWrap: "wrap", justifyContent: "flex-end" }}>
                        {r.owner_kind !== "new_hire" && (
                          <Pill fg={T.purple} bg={T.purpleLt}>{ownerName(r)}</Pill>
                        )}
                        <Pill fg={cat.fg} bg={cat.bg}>{cat.label}</Pill>
                      </div>
                    </div>
                    {r.description && (
                      <div style={{ fontSize: 11, color: T.slate500, marginTop: 3, lineHeight: 1.45 }}>{r.description}</div>
                    )}
                    {groups.map((g, gi) => (
                      <div key={gi} style={{ marginTop: 8 }}>
                        {g.group && (
                          <div style={{
                            fontSize: 10, fontWeight: 700, color: T.slate500,
                            textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 3,
                          }}>{g.group}</div>
                        )}
                        <ul style={{ margin: 0, paddingLeft: 18, display: "grid", gap: 3 }}>
                          {g.items.map((label2, ix) => (
                            <li key={ix} style={{ fontSize: 12, color: T.slate700, lineHeight: 1.4 }}>{label2}</li>
                          ))}
                        </ul>
                      </div>
                    ))}
                    {after.length > 0 && (
                      <div style={{ fontSize: 10, color: T.amber, marginTop: 8, fontWeight: 600 }}>
                        After: {after.join(", ")}
                      </div>
                    )}
                    <div style={{ fontSize: 10, color: T.slate400, marginTop: 6 }}>
                      {appliesToText(r)}
                    </div>
                  </div>
                );
            };

            const cols = trackColumns(rows);
            const gridStyle = {
              display: "grid",
              gridTemplateColumns: "repeat(auto-fit, minmax(300px, 1fr))",
              gap: cols ? 16 : 10, alignItems: "start",
            };
            if (!cols) return <div style={gridStyle}>{rows.map(renderRow)}</div>;
            return (
              <div style={gridStyle}>
                {cols.map(c => (
                  <div key={c.name || "_"} style={{ display: "grid", gap: 10, alignContent: "start" }}>
                    {c.name && <div style={trackHeadStyle}>{c.name}</div>}
                    {c.steps.map(renderRow)}
                  </div>
                ))}
              </div>
            );
            })()}
          </Card>
        );
      })}
    </div>
  );
}

// ─── main component ────────────────────────────────
export default function Onboarding({ userRole, userId }) {
  const isAdmin = ADMIN_ROLES.includes(userRole);
  const { loading, error, plans, steps, team, phases, candidates, myTeamMemberId, reload } = useOnboardingData(userId, isAdmin);

  // URL-persisted so refresh keeps the same plan open. Replaces the prior
  // useState + manual ?plan= useEffect pair — useTabParam handles both the
  // read on mount and the write on every setSelectedPlanId call.
  const [selectedPlanId, setSelectedPlanId] = useTabParam("plan", null);
  const [tab, setTab, tabHref] = useTabParam("subtab", "plans", ["plans", "template"]);
  const [showCreate, setShowCreate] = useState(false);
  const [actionError, setActionError] = useState("");

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
    if (row) return { name: row.name, blurb: row.blurb || "", stage: row.stage };
    const fb = PHASE_LABELS[phase];
    return fb ? { ...fb, stage: null } : { name: `Phase ${phase}`, blurb: "", stage: null };
  }, [phases]);

  // "Alvi" / "Peter" / whoever owns a step that is not the new hire's own.
  const ownerName = useCallback((step) => {
    if (step.assigned_to) {
      const t = (team || []).find(x => x.id === step.assigned_to);
      if (t) return memberName(t);
    }
    if (step.owner_kind === "agent") return "Peter";
    if (step.owner_kind === "admin") return "Admin";
    return "New hire";
  }, [team]);

  const candidateName = useCallback((c) => {
    if (!c) return "Candidate";
    const n = `${c.first_name || ""} ${c.last_name || ""}`.trim();
    return n || c.candidate_name || "Candidate";
  }, []);

  const subjectName = useCallback((plan) => {
    if (plan.team_member_id) return memberName(teamById.get(plan.team_member_id));
    return candidateName(candidateById.get(plan.candidate_id));
  }, [teamById, candidateById, candidateName]);

  const stepsByPlan = useMemo(() => {
    const m = new Map();
    steps.forEach(s => {
      if (!m.has(s.plan_id)) m.set(s.plan_id, []);
      m.get(s.plan_id).push(s);
    });
    return m;
  }, [steps]);

  // Team-tier view: auto-select their own plan if they have one
  useEffect(() => {
    if (!isAdmin && myTeamMemberId && !selectedPlanId && plans.length) {
      const mine = plans.find(p => p.team_member_id === myTeamMemberId && (p.status === "active" || p.status === "paused"));
      if (mine) setSelectedPlanId(mine.id);
    }
  }, [isAdmin, myTeamMemberId, plans, selectedPlanId]);

  // ─── actions ──────────────────────────────────
  const handleToggleStep = async (step) => {
    setActionError("");
    const newVal = step.completed_at ? null : new Date().toISOString();
    const { error: err } = await supabase.from("team_onboarding_steps")
      .update({ completed_at: newVal, completed_by: newVal ? userId : null })
      .eq("id", step.id);
    if (err) { setActionError(err.message); return; }
    await reload();
  };

  // Ticking the last sub-item completes the step; unticking any re-opens it.
  const handleToggleSubstep = async (step, label) => {
    setActionError("");
    const subs = subAll(step.substeps);
    const cur = Array.isArray(step.substeps_done) ? step.substeps_done : [];
    const next = cur.includes(label) ? cur.filter(l => l !== label) : [...cur, label];
    const allDone = subs.length > 0 && subs.every(s => next.includes(s));
    const patch = { substeps_done: next };
    if (allDone && !step.completed_at) {
      patch.completed_at = new Date().toISOString();
      patch.completed_by = userId;
    } else if (!allDone && step.completed_at) {
      patch.completed_at = null;
      patch.completed_by = null;
    }
    const { error: err } = await supabase.from("team_onboarding_steps")
      .update(patch)
      .eq("id", step.id);
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

  // Team-tier view — no plan
  if (!isAdmin) {
    const mine = plans.filter(p => p.team_member_id === myTeamMemberId);
    if (mine.length === 0) {
      return (
        <div style={{ padding: 20 }}>
          <Card>
            <div style={{ fontSize: 14, color: T.slate800, marginBottom: 6, fontWeight: 600 }}>No onboarding plan yet</div>
            <div style={{ fontSize: 12, color: T.slate500 }}>
              You don't have an onboarding schedule assigned. Reach out to Peter if you were expecting one.
            </div>
          </Card>
        </div>
      );
    }
    // If a plan is selected, show it. Else, show the first active/paused plan.
    const activePlan = mine.find(p => p.id === selectedPlanId) || mine.find(p => p.status === "active" || p.status === "paused") || mine[0];
    return (
      <div style={{ padding: 20 }}>
        <PlanDetail
          plan={activePlan}
          steps={stepsByPlan.get(activePlan.id) || []}
          subjectName={subjectName(activePlan)}
          isCandidate={!activePlan.team_member_id}
          phaseMeta={phaseMeta}
          ownerName={ownerName}
          onBack={() => setSelectedPlanId(null)}
          onToggleStep={handleToggleStep}
          onToggleSubstep={handleToggleSubstep}
          onUpdateStepNotes={handleUpdateStepNotes}
          onDeletePlan={handleDeletePlan}
          onChangeStatus={handleChangeStatus}
          isAdmin={false}
        />
        {actionError && <Card style={{ marginTop: 10, background: T.redLt }}><div style={{ color: T.red, fontSize: 12 }}>{actionError}</div></Card>}
      </div>
    );
  }

  // Admin view
  if (tab === "template") {
    return (
      <div style={{ padding: 20 }}>
        <ModuleHeader tab={tab} tabHref={tabHref} onSelectTab={setTab} />
        <TemplateTab phaseMeta={phaseMeta} ownerName={ownerName} />
      </div>
    );
  }

  const selectedPlan = plans.find(p => p.id === selectedPlanId);

  if (selectedPlan) {
    return (
      <div style={{ padding: 20 }}>
        <PlanDetail
          plan={selectedPlan}
          steps={stepsByPlan.get(selectedPlan.id) || []}
          subjectName={subjectName(selectedPlan)}
          isCandidate={!selectedPlan.team_member_id}
          phaseMeta={phaseMeta}
          ownerName={ownerName}
          onBack={() => setSelectedPlanId(null)}
          onToggleStep={handleToggleStep}
          onToggleSubstep={handleToggleSubstep}
          onUpdateStepNotes={handleUpdateStepNotes}
          onDeletePlan={handleDeletePlan}
          onChangeStatus={handleChangeStatus}
          isAdmin={true}
        />
        {actionError && <Card style={{ marginTop: 10, background: T.redLt }}><div style={{ color: T.red, fontSize: 12 }}>{actionError}</div></Card>}
      </div>
    );
  }

  // Admin list
  const grouped = {
    active:    plans.filter(p => p.status === "active"),
    paused:    plans.filter(p => p.status === "paused"),
    completed: plans.filter(p => p.status === "completed"),
    archived:  plans.filter(p => p.status === "archived"),
  };

  return (
    <div style={{ padding: 20 }}>
      <ModuleHeader
        tab={tab}
        tabHref={tabHref}
        onSelectTab={setTab}
        action={<Button variant="primary" onClick={() => setShowCreate(true)}>+ New plan</Button>}
      />

      {actionError && <Card style={{ marginBottom: 12, background: T.redLt }}><div style={{ color: T.red, fontSize: 12 }}>{actionError}</div></Card>}

      {plans.length === 0 && (
        <Card>
          <div style={{ fontSize: 14, color: T.slate800, marginBottom: 6, fontWeight: 600 }}>No onboarding plans yet</div>
          <div style={{ fontSize: 12, color: T.slate500, marginBottom: 12 }}>
            Compile a plan for a new hire and the appropriate steps will be pulled from the step library based on their role.
          </div>
          <Button variant="primary" onClick={() => setShowCreate(true)}>+ Create the first plan</Button>
        </Card>
      )}

      {["active", "paused", "completed", "archived"].map(status => {
        const rows = grouped[status];
        if (!rows.length) return null;
        const col = STATUS_COLORS[status];
        return (
          <div key={status} style={{ marginBottom: 16 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: T.slate700, textTransform: "uppercase", letterSpacing: 0.5 }}>
                {col.label}
              </div>
              <div style={{ fontSize: 11, color: T.slate400 }}>({rows.length})</div>
            </div>
            {rows.map(plan => (
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
      })}

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
