import { useState, useMemo, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useSupabaseTable } from "../lib/hooks.js";
import EmptyState from "../components/EmptyState.jsx";

// ============================================================
// BCC TASKS & GOALS MODULE v1.2
// Business Command Center — State Farm Agent Edition
// Built by Imaginary Farms LLC · imaginary-farms.com
//
// SECTIONS:
//   1. To-Dos     — Tasks pushed to this week's focus, grouped by category (default landing)
//   2. Overview   — Full task list (epics + stories + tasks), create, filter, complete
//   3. Goals      — Annual goals with progress tracking
//   4. Completed  — History of completed tasks
//
// KEY FEATURES:
//   • Six fixed task categories (web app, admin, marketing,
//     training, handbook, playbook) backed by DB CHECK constraint
//   • Star toggle pushes a task to This Week's to-dos
//   • Priority system: critical / high / medium / low
//   • Tasks created by agent, Claude, or automations
//   • Goals track revenue, AIPP, team, compliance, personal
//
// DATA: Reads tasks, goals tables in Supabase.
//       module_reference column removed 2026-06-29; Module concept
//       collapsed into task_category.
// ============================================================


// ─── Design Tokens ────────────────────────────────────────────
import { T } from "../lib/theme.js";

// ─── Priority Config ──────────────────────────────────────────
const PRIORITY = {
  critical: { color:T.red,    bg:T.redLt,    label:"Critical", dot:"🔴" },
  high:     { color:"#EA580C", bg:"#FFF7ED",  label:"High",     dot:"🟠" },
  medium:   { color:T.amber,  bg:T.amberLt,  label:"Medium",   dot:"🟡" },
  low:      { color:T.slate500,bg:T.slate100, label:"Low",      dot:"⚪" },
};

// ─── Task Category Config ─────────────────────────────────────
// Six fixed categories on every task — distinct from module_reference (related BCC area).
// DB column: task_category, vocabulary locked by CHECK constraint (migration 040).
const TASK_CATEGORIES = {
  web_app:           { label:"Web App",          icon:"💻", color:T.teal     },
  admin:             { label:"Admin",            icon:"🗂️", color:T.slate500 },
  finances:          { label:"Finances",         icon:"💰", color:T.blue     },
  marketing:         { label:"Marketing",        icon:"📣", color:T.purple   },
  team_development:  { label:"Team Development", icon:"🎓", color:T.amber    },
  handbook:          { label:"Handbook",         icon:"📕", color:T.red      },
  playbook:          { label:"Playbook",         icon:"📘", color:T.green    },
};
const TASK_CATEGORY_ORDER = ["web_app","admin","finances","marketing","team_development","handbook","playbook"];
const categoryConfig = (key) => TASK_CATEGORIES[key] || null;

// ─── Task Type Config (Epic > Story > Task) ───────────────────
// Three-level hierarchy added by migration 040.
//   Epic  = big body of work (weeks/months). Cannot have a parent.
//   Story = unit of value (days). Parent should be an Epic.
//   Task  = concrete action (hours). Parent should be a Story (or another Task).
// DB columns: task_type (CHECK 'epic'|'story'|'task'), parent_task_id (FK self).
const TASK_TYPES = {
  epic:  { label:"Epic",  color:T.purple,   bg:"#F5F3FF", icon:"🎯", desc:"Big body of work · weeks–months" },
  story: { label:"Story", color:T.blue,     bg:T.blueLt || "#EFF6FF", icon:"📖", desc:"Unit of value · days" },
  task:  { label:"Task",  color:T.slate500, bg:T.slate100, icon:"✓",  desc:"Concrete action · hours" },
};
const TASK_TYPE_ORDER = ["epic","story","task"];
const typeConfig = (key) => TASK_TYPES[key] || TASK_TYPES.task;

// ─── Goal Category Config ─────────────────────────────────────
const GOAL_CATS = {
  aipp:       { label:"AIPP",       color:T.green,  icon:"🎯" },
  revenue:    { label:"Revenue",    color:T.blue,   icon:"💰" },
  team:       { label:"Team",       color:T.purple, icon:"👥" },
  compliance: { label:"Compliance", color:T.red,    icon:"🛡️" },
  personal:   { label:"Personal",   color:T.amber,  icon:"⭐" },
  growth:     { label:"Growth",     color:T.teal,   icon:"📈" },
};

// ─── Mock Data ────────────────────────────────────────────────
const MOCK_TASKS = [
  // Open tasks
  { id:"t1",  title:"Fix Daily Briefing automation — Gmail OAuth expired",       priority:"critical", status:"open",        module:"automations", due_date:"Apr 27, 2026", assigned_to:"Jane Smith",  created_by:"system",      description:"Gmail OAuth token expired causing Daily Briefing to fail. Reconnect Gmail in Composio dashboard.", created_at:"Today" },
  { id:"t2",  title:"Complete monthly auto application compliance review",        priority:"high",     status:"open",        module:"compliance",  due_date:"Apr 30, 2026", assigned_to:"Jane Smith",  created_by:"system",      description:"Pull RAZ000BT report. Review all required auto app metrics. Review SAM report (RAZ000BV). Document findings.", created_at:"Apr 25" },
  { id:"t3",  title:"Complete monthly Altered Monies history review",             priority:"high",     status:"open",        module:"financials",  due_date:"Apr 30, 2026", assigned_to:"Jane Smith",  created_by:"system",      description:"Review and document Altered Monies history for April. Required standing compliance item.", created_at:"Apr 25" },
  { id:"t4",  title:"Manually post Instagram content — Monday April 27",          priority:"high",     status:"open",        module:"social",      due_date:"Apr 27, 2026", assigned_to:"Jane Smith",  created_by:"automations", description:"Behind the scenes at the agency this Monday morning. Coffee, team huddle, and a full week ahead. ☕ — scheduled for 11AM", created_at:"Today" },
  { id:"t5",  title:"Review Q1 bank reconciliation",                               priority:"medium",   status:"open",        module:"financials",  due_date:"May 3, 2026",  assigned_to:"Jane Smith",  created_by:"automation",      description:"Q1 bank reconciliation is ready to review. Verify all GL entries match bank statements for January, February, and March.", created_at:"Apr 26" },
  { id:"t6",  title:"Send Kimberly Yow reseller agreement for signature",          priority:"medium",   status:"in_progress", module:"general",     due_date:"May 5, 2026",  assigned_to:"Jane Smith",  created_by:"Jane Smith",  description:"Channel partner reseller agreement ready. Send via DocuSign and follow up within 3 business days.", created_at:"Apr 24" },
  { id:"t7",  title:"Schedule discovery call with new prospect — Mike Anderson",   priority:"medium",   status:"open",        module:"general",     due_date:"May 1, 2026",  assigned_to:"Jane Smith",  created_by:"Jane Smith",  description:"Referred by Alyssa. Auto agency owner. Interested in BCC setup.", created_at:"Apr 23" },
  { id:"t8",  title:"Post resume — April interview focus review with Marcus",      priority:"medium",   status:"open",        module:"hr",          due_date:"Apr 29, 2026", assigned_to:"Marcus T.",   created_by:"automations", description:"New applicant received — Jamie Chen. AI score: 8/10. Review One Page Interview Focus together before scheduling interview.", created_at:"Apr 26" },
  { id:"t9",  title:"Begin E&O insurance renewal process",                         priority:"low",      status:"open",        module:"compliance",  due_date:"May 1, 2026",  assigned_to:"Jane Smith",  created_by:"system",      description:"E&O insurance renews August 2026. Begin renewal process 90 days in advance. Contact Hartford for renewal quote.", created_at:"Apr 27" },
  { id:"t10", title:"Update staff performance metrics for March",                  priority:"low",      status:"open",        module:"hr",          due_date:"May 3, 2026",  assigned_to:"Jane Smith",  created_by:"system",      description:"Log March KPIs for Marcus Thompson and Priya Patel in the staff performance table.", created_at:"Apr 1" },
  { id:"t11", title:"Draft April social media batch for next week",                priority:"low",      status:"open",        module:"social",      due_date:"Apr 30, 2026", assigned_to:"Jane Smith",  created_by:"Jane Smith",  description:"Batch create May 4-8 social posts. Use content calendar framework: Mon Educate, Tue Community, Wed Connect, Thu Educate/Celebrate, Fri Invite.", created_at:"Apr 26" },

  // Completed
  { id:"t12", title:"Process April COMP_RECAP from State Farm",                   priority:"high",     status:"completed",   module:"financials",  due_date:"Apr 26, 2026", assigned_to:"Jane Smith",  created_by:"automations", description:"", created_at:"Apr 20", completed_at:"Apr 26" },
  { id:"t13", title:"Run April payroll",                                           priority:"high",     status:"completed",   module:"financials",  due_date:"Apr 19, 2026", assigned_to:"Jane Smith",  created_by:"Jane Smith",  description:"", created_at:"Apr 15", completed_at:"Apr 19" },
  { id:"t14", title:"Post Marcus work anniversary social content",                 priority:"medium",   status:"completed",   module:"social",      due_date:"Apr 25, 2026", assigned_to:"Jane Smith",  created_by:"Jane Smith",  description:"", created_at:"Apr 23", completed_at:"Apr 25" },
  { id:"t15", title:"Complete Q1 staff performance review",                        priority:"medium",   status:"completed",   module:"hr",          due_date:"Apr 15, 2026", assigned_to:"Jane Smith",  created_by:"system",      description:"", created_at:"Apr 1",  completed_at:"Apr 14" },
  { id:"t16", title:"March PFA bank statement reconciliation",                     priority:"high",     status:"completed",   module:"financials",  due_date:"Apr 14, 2026", assigned_to:"Jane Smith",  created_by:"system",      description:"", created_at:"Apr 1",  completed_at:"Apr 12" },
];

const MOCK_GOALS = [
  {
    id:"g1", title:"Hit AIPP Target — 2026",
    description:"Achieve full AIPP payout for 2026 program year",
    category:"aipp", unit:"dollars",
    target_value:142000, current_value:67450,
    target_date:"Dec 31, 2026",
    status:"active",
    notes:"On track — 47.5% achieved with 8 months remaining. Prior year final was $138,200.",
    monthly_data:[15200,14800,18650,18800,0,0,0,0,0,0,0,0],
  },
  {
    id:"g2", title:"Annual Revenue Target — 2026",
    description:"Total agency gross revenue for the year",
    category:"revenue", unit:"dollars",
    target_value:580000, current_value:187420,
    target_date:"Dec 31, 2026",
    status:"active",
    notes:"YTD $187,420 through April. On pace for $562K at current run rate — slightly below target. May need to push new business in Q2.",
    monthly_data:[41200,38900,44600,48240,0,0,0,0,0,0,0,0],
  },
  {
    id:"g3", title:"New Business Premium Growth — 15%",
    description:"Grow new business premium by 15% vs 2025",
    category:"growth", unit:"percentage",
    target_value:15, current_value:9,
    target_date:"Dec 31, 2026",
    status:"active",
    notes:"Currently at 9% growth YTD. Need to accelerate new business production in Q2-Q3.",
    monthly_data:null,
  },
  {
    id:"g4", title:"Add One Licensed Team Member — Q3",
    description:"Hire and license one additional team member by September 2026",
    category:"team", unit:"count",
    target_value:1, current_value:0,
    target_date:"Sep 30, 2026",
    status:"active",
    notes:"Resume Scanner is active. Jamie Chen interview in progress (score 8/10). Marcus can help onboard.",
    monthly_data:null,
  },
  {
    id:"g5", title:"Reduce Operating Expense Ratio Below 45%",
    description:"Keep total operating expenses below 45% of gross income",
    category:"revenue", unit:"percentage",
    target_value:45, current_value:43.2,
    target_date:"Dec 31, 2026",
    status:"active",
    notes:"Currently at 43.2% — ahead of target. Monitor payroll ratio as team grows.",
    monthly_data:null,
  },
  {
    id:"g6", title:"Complete Annual Compliance Training",
    description:"Complete all required State Farm annual compliance and ethics training",
    category:"compliance", unit:"count",
    target_value:1, current_value:0,
    target_date:"Dec 31, 2026",
    status:"active",
    notes:"Due by December 31. Schedule Q3 to allow time for completion.",
    monthly_data:null,
  },
];

// ─── Helpers ──────────────────────────────────────────────────
const pct = (curr, target) => Math.min(100, Math.round((curr / target) * 100));
const fmt = (n, unit) => {
  if (unit === "dollars") return "$" + n.toLocaleString();
  if (unit === "percentage") return n + "%";
  return n.toString();
};
const parseDueDate = (s) => {
  if (!s) return null;
  // Accept "Apr 27, 2026" (normalized) or bare "Apr 27" (mock — assume current year).
  const d = /,\s*\d{4}/.test(s) ? new Date(s) : new Date(s + ", " + new Date().getFullYear());
  return Number.isNaN(d.getTime()) ? null : d;
};
const daysUntil = (due) => {
  const d = parseDueDate(due);
  if (!d) return Infinity;
  const today = new Date(); today.setHours(0,0,0,0);
  const target = new Date(d); target.setHours(0,0,0,0);
  return Math.round((target - today) / 86400000);
};
const isOverdue = (due) => {
  const n = daysUntil(due);
  return Number.isFinite(n) && n < 0;
};

// ─── Shared Components ────────────────────────────────────────
const Card = ({ children, style={} }) => (
  <div style={{ background:T.white, border:`1px solid ${T.slate200}`, borderRadius:12, padding:"16px 18px", ...style }}>
    {children}
  </div>
);


const ProgressBar = ({ value, max, color=T.blue, height=8 }) => {
  const p = pct(value, max);
  return (
    <div style={{ height, background:T.slate100, borderRadius:height/2, overflow:"hidden" }}>
      <div style={{ height:"100%", width:`${p}%`, background:color, borderRadius:height/2, transition:"width 0.7s ease" }} />
    </div>
  );
};

// ─── Task Card Component ──────────────────────────────────────
const TaskCard = ({ task, allTasks, depth=0, onComplete, onNavigate, onToggleFocus, isExpanded=false, onToggleExpand }) => {
  // Expansion state is lifted to TasksList (expandedIds) so it can drive both description and children visibility.
  const pr = PRIORITY[task.priority] || PRIORITY.medium;
  const cat = categoryConfig(task.task_category);
  const typ = typeConfig(task.task_type || "task");
  const overdue = task.status === "open" && isOverdue(task.due_date);
  const days = daysUntil(task.due_date);
  const isCompleted = task.status === "completed";
  const inFocus = !!task.in_weekly_focus;
  // Hierarchy context (read-only):
  const parent = (task.parent_task_id && Array.isArray(allTasks))
    ? allTasks.find(t => t.id === task.parent_task_id) : null;
  const children = (Array.isArray(allTasks) && (task.task_type === "epic" || task.task_type === "story"))
    ? allTasks.filter(t => t.parent_task_id === task.id) : [];
  const childOpen = children.filter(c => c.status !== "completed").length;
  // Direct-children counts power the pill label (drill-down: each level's toggle reveals its own children).
  const childStories = children.filter(c => c.task_type === "story").length;
  const childTasks   = children.filter(c => (c.task_type || "task") === "task").length;
  const hasDescription = !!task.description;
  const hasChildren    = children.length > 0 && (task.task_type === "epic" || task.task_type === "story");
  const showPill       = hasChildren || hasDescription;
  // Indent based on depth in nested view (max 2 levels visible)
  const indent = Math.min(depth, 2) * 18;

  // Visual hierarchy by task_type — epic > story > task carries visible weight.
  const isEpic  = task.task_type === "epic";
  const isStory = task.task_type === "story";
  const cardBg     = (isEpic || isStory) ? typ.bg : T.white;
  const accentW    = isEpic ? 6 : isStory ? 4 : 3;
  const titleSize  = isEpic ? 14 : isStory ? 13 : 12;
  const titleWt    = isCompleted ? 400 : isEpic ? 700 : 600;

  return (
    <div style={{
      background:cardBg,
      border:`1px solid ${isExpanded?T.blue:overdue?T.red:T.slate200}`,
      borderLeft:`${accentW}px solid ${overdue?T.red:typ.color}`,
      borderRadius:10, overflow:"hidden",
      opacity:isCompleted?0.7:1,
      marginLeft:indent,
    }}>
      <div style={{ display:"flex", alignItems:"center", gap:10, padding:"11px 12px", flexWrap:"wrap" }}>
        {/* Checkbox */}
        {!isCompleted ? (
          <div
            onClick={() => onComplete(task.id)}
            style={{ width:20, height:20, borderRadius:5, border:`2px solid ${T.slate300}`, background:"transparent", cursor:"pointer", flexShrink:0, display:"flex", alignItems:"center", justifyContent:"center", transition:"all 0.15s" }}
            title="Mark complete"
          />
        ) : (
          <div style={{ width:20, height:20, borderRadius:5, background:T.green, flexShrink:0, display:"flex", alignItems:"center", justifyContent:"center" }}>
            <span style={{ color:T.white, fontSize:11, lineHeight:1 }}>✓</span>
          </div>
        )}

        {/* Content */}
        <div style={{ flex:1, minWidth:0, cursor: showPill ? "pointer" : "default" }} onClick={() => showPill && onToggleExpand && onToggleExpand(task.id)}>
          {/* Parent breadcrumb */}
          {parent && (
            <div style={{ fontSize:10, color:T.slate400, marginBottom:2, display:"flex", alignItems:"center", gap:4, flexWrap:"wrap" }}>
              <span style={{ opacity:0.7 }}>{typeConfig(parent.task_type || "task").icon}</span>
              <span style={{ whiteSpace:"nowrap", overflow:"hidden", textOverflow:"ellipsis", maxWidth:240 }}>{parent.title}</span>
              <span style={{ opacity:0.5 }}>›</span>
            </div>
          )}
          <div style={{ display:"flex", alignItems:"center", gap:8, marginBottom:3, flexWrap:"wrap" }}>
            <span style={{
              display:"inline-flex", alignItems:"center", gap:4,
              fontSize:9, fontWeight:700,
              padding:"3px 8px", borderRadius:20,
              background:typ.color, color:T.white,
              textTransform:"uppercase", letterSpacing:"0.04em",
              flexShrink:0, lineHeight:1
            }}>
              <span style={{ fontSize:11, lineHeight:1 }}>{typ.icon}</span>
              {typ.label}
            </span>
            <span style={{ fontSize:titleSize, fontWeight:titleWt, color:isCompleted?T.slate400:T.slate800, textDecoration:isCompleted?"line-through":"none" }}>
              {task.title}
            </span>
          </div>
          <div style={{ display:"flex", alignItems:"center", gap:8, flexWrap:"wrap" }}>
            <span style={{ fontSize:9, fontWeight:600, padding:"2px 7px", borderRadius:20, background:pr.bg, color:pr.color }}>{pr.label}</span>
            {cat && <span style={{ fontSize:9, fontWeight:600, padding:"2px 7px", borderRadius:20, background:cat.color+"20", color:cat.color }}>{cat.icon} {cat.label}</span>}
            {showPill && (() => {
              // Build label: "N stories" / "N tasks" / "Details" depending on what expanding reveals.
              const labelParts = [];
              if (task.task_type === "epic" && childStories > 0) {
                labelParts.push(`${childStories} ${childStories === 1 ? "story" : "stories"}`);
              }
              if ((task.task_type === "epic" || task.task_type === "story") && childTasks > 0) {
                labelParts.push(`${childTasks} ${childTasks === 1 ? "task" : "tasks"}`);
              }
              if (labelParts.length === 0 && hasDescription) {
                labelParts.push("Details");
              }
              const label = labelParts.join(" · ");
              return (
                <button
                  onClick={(e) => { e.stopPropagation(); onToggleExpand && onToggleExpand(task.id); }}
                  title={isExpanded
                    ? (hasChildren ? "Collapse — hide children" + (hasDescription ? " and description" : "") : "Hide details")
                    : (hasChildren ? "Expand — show children" + (hasDescription ? " and description" : "") : "Show details")}
                  style={{
                    display:"inline-flex", alignItems:"center", gap:6,
                    fontSize:10, fontWeight:600,
                    padding:"4px 11px 4px 9px", borderRadius:14,
                    background: isExpanded ? typ.bg     : T.slate100,
                    color:      isExpanded ? typ.color  : T.slate600,
                    border:     `1px solid ${isExpanded ? typ.color + "55" : T.slate200}`,
                    cursor:"pointer", lineHeight:1,
                    transition:"background 0.12s, color 0.12s, border-color 0.12s"
                  }}
                >
                  <span style={{ fontSize:9, lineHeight:1 }}>{isExpanded ? "▼" : "▶"}</span>
                  <span>{label}</span>
                </button>
              );
            })()}
            {inFocus && !isCompleted && <span style={{ fontSize:9, fontWeight:600, padding:"2px 7px", borderRadius:20, background:T.amberLt, color:T.amber, border:`1px solid ${T.amber}40` }}>★ This Week</span>}
            <span style={{ fontSize:10, color:overdue?T.red:days<=3?T.amber:T.slate400, fontWeight:overdue||days<=3?600:400 }}>
              {isCompleted ? `Completed ${task.completed_at}` : overdue ? `Overdue — ${task.due_date}` : days===0 ? "Due today" : days===1 ? "Due tomorrow" : `Due ${task.due_date}`}
            </span>
            {task.assigned_to && <span style={{ fontSize:10, color:T.slate400 }}>→ {task.assigned_to_name || task.assigned_to}</span>}
            <span style={{ fontSize:9, color:T.slate400, fontStyle:"italic" }}>by {task.created_by}</span>
          </div>
        </div>

        {/* Push to this week's to-dos */}
        {!isCompleted && (
          <button
            onClick={(e) => { e.stopPropagation(); onToggleFocus && onToggleFocus(task.id, !inFocus); }}
            title={inFocus ? "Remove from this week's to-dos" : "Push to this week's to-dos"}
            aria-label={inFocus ? "Remove from this week's to-dos" : "Push to this week's to-dos"}
            style={{
              width:40, height:40, padding:0,
              display:"flex", alignItems:"center", justifyContent:"center",
              fontSize:20, lineHeight:1,
              color: inFocus ? T.amber : T.slate400,
              background: inFocus ? T.amberLt : "transparent",
              border:"none", borderRadius:10, cursor:"pointer", flexShrink:0,
              WebkitTapHighlightColor:"transparent"
            }}
          >
            {inFocus ? "★" : "☆"}
          </button>
        )}


        <button
          onClick={(e) => { e.stopPropagation(); onToggleExpand && onToggleExpand(task.id); }}
          title={isExpanded ? "Collapse" : "Expand"}
          aria-label={isExpanded ? "Collapse" : "Expand"}
          style={{
            width:40, height:40, padding:0,
            display:"flex", alignItems:"center", justifyContent:"center",
            fontSize:14, lineHeight:1,
            color:T.slate500,
            background:"transparent", border:"none", borderRadius:10,
            cursor:"pointer", flexShrink:0,
            WebkitTapHighlightColor:"transparent"
          }}>
          {isExpanded ? "▲" : "▼"}
        </button>
      </div>

      {isExpanded && task.description && (
        <div style={{ padding:"0 12px 12px 46px", borderTop:`1px solid ${T.slate100}` }}>
          <div style={{ fontSize:12, color:T.slate600, lineHeight:1.6, marginTop:8, marginBottom:8 }}>
            {task.description}
          </div>
          
        </div>
      )}
    </div>
  );
};

// ─── New Task Modal ───────────────────────────────────────────
const NewTaskModal = ({ onSave, onCancel, allTasks = [], defaultType = "task", defaultParentId = null, adminUsers = [], currentUserId = null, currentUserRole = null }) => {
  // Owner can assign to any admin; manager can only assign to themselves.
  const canAssignOthers = currentUserRole === "owner";
  const assignableUsers = canAssignOthers
    ? adminUsers
    : adminUsers.filter(u => u.id === currentUserId);
  const [form, setForm] = useState({
    title:"", description:"", priority:"medium", task_category:"",
    in_weekly_focus:false, due_date:"", assigned_to: currentUserId || "",
    task_type: defaultType,
    parent_task_id: defaultParentId || "",
  });
  const set = (k, v) => setForm(f => {
    const next = { ...f, [k]:v };
    // Epics cannot have a parent; clear parent if type changes to epic.
    if (k === "task_type" && v === "epic") next.parent_task_id = "";
    return next;
  });

  // Eligible parents depend on type:
  //   epic  -> none (epics are top-level)
  //   story -> any epic
  //   task  -> any story OR any task (lets us nest task-under-task if needed)
  const eligibleParents = (() => {
    if (form.task_type === "epic") return [];
    if (form.task_type === "story") return allTasks.filter(t => t.task_type === "epic" && t.status !== "completed");
    // task
    return allTasks.filter(t => (t.task_type === "story" || t.task_type === "task") && t.status !== "completed");
  })();

  const typ = typeConfig(form.task_type);
  const heading = `New ${typ.label}`;

  return (
    <div style={{ position:"fixed", inset:0, background:"rgba(15,23,42,0.5)", display:"flex", alignItems:"center", justifyContent:"center", zIndex:1000, padding:20 }}>
      <div style={{ background:T.white, borderRadius:16, width:"100%", maxWidth:500, boxShadow:"0 20px 60px rgba(0,0,0,0.2)", overflow:"hidden" }}>
        <div style={{ padding:"16px 20px", borderBottom:`1px solid ${T.slate200}`, display:"flex", justifyContent:"space-between", alignItems:"center" }}>
          <span style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>{typ.icon} {heading}</span>
          <button onClick={onCancel} style={{ background:"none", border:"none", fontSize:22, color:T.slate400, cursor:"pointer", padding:"4px 10px", lineHeight:1 }}>×</button>
        </div>
        <div style={{ padding:20 }}>
          {[
            { label:"TITLE", key:"title", type:"text", placeholder:"What needs to be done?" },
            { label:"DESCRIPTION", key:"description", type:"textarea", placeholder:"Additional details..." },
          ].map(f => (
            <div key={f.key} style={{ marginBottom:12 }}>
              <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>{f.label}</label>
              {f.type === "textarea" ? (
                <textarea value={form[f.key]} onChange={e => set(f.key, e.target.value)} placeholder={f.placeholder} rows={3}
                  style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate800, border:`1px solid ${T.slate200}`, borderRadius:8, outline:"none", resize:"none", fontFamily:"inherit", boxSizing:"border-box" }} />
              ) : (
                <input value={form[f.key]} onChange={e => set(f.key, e.target.value)} placeholder={f.placeholder}
                  style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate800, border:`1px solid ${T.slate200}`, borderRadius:8, outline:"none", boxSizing:"border-box" }} />
              )}
            </div>
          ))}
          {/* Type + Parent — hierarchy controls */}
          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(160px, 1fr))", gap:12, marginBottom:12 }}>
            <div>
              <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>TYPE</label>
              <select value={form.task_type} onChange={e => set("task_type", e.target.value)}
                style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate700, border:`1px solid ${T.slate200}`, borderRadius:8, background:T.white, outline:"none" }}>
                {TASK_TYPE_ORDER.map(t => <option key={t} value={t}>{TASK_TYPES[t].icon} {TASK_TYPES[t].label}</option>)}
              </select>
              <div style={{ fontSize:10, color:T.slate400, marginTop:4 }}>{typ.desc}</div>
            </div>
            <div>
              <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>PARENT</label>
              <select value={form.parent_task_id || ""} onChange={e => set("parent_task_id", e.target.value || null)}
                disabled={form.task_type === "epic"}
                style={{ width:"100%", padding:"8px 10px", fontSize:12, color:form.task_type==="epic"?T.slate400:T.slate700, border:`1px solid ${T.slate200}`, borderRadius:8, background:form.task_type==="epic"?T.slate100:T.white, outline:"none" }}>
                <option value="">{form.task_type === "epic" ? "— Epics are top-level —" : "— None (standalone) —"}</option>
                {eligibleParents.map(p => (
                  <option key={p.id} value={p.id}>{typeConfig(p.task_type||"task").icon} {p.title.length>60 ? p.title.slice(0,60)+"…" : p.title}</option>
                ))}
              </select>
            </div>
          </div>
          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(140px, 1fr))", gap:12, marginBottom:12 }}>
            <div>
              <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>PRIORITY</label>
              <select value={form.priority} onChange={e => set("priority", e.target.value)}
                style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate700, border:`1px solid ${T.slate200}`, borderRadius:8, background:T.white, outline:"none" }}>
                {Object.keys(PRIORITY).map(p => <option key={p} value={p}>{PRIORITY[p].label}</option>)}
              </select>
            </div>
<div>
              <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>CATEGORY</label>
              <select value={form.task_category} onChange={e => set("task_category", e.target.value)}
                style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate700, border:`1px solid ${T.slate200}`, borderRadius:8, background:T.white, outline:"none" }}>
                <option value="">— None —</option>
                {TASK_CATEGORY_ORDER.map(c => <option key={c} value={c}>{TASK_CATEGORIES[c].icon} {TASK_CATEGORIES[c].label}</option>)}
              </select>
            </div>
            <div>
              <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>DUE DATE</label>
              <input type="text" value={form.due_date} onChange={e => set("due_date", e.target.value)} placeholder="May 1, 2026"
                style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate800, border:`1px solid ${T.slate200}`, borderRadius:8, outline:"none", boxSizing:"border-box" }} />
            </div>
            <div>
              <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>ASSIGNED TO</label>
              <select value={form.assigned_to || ""} onChange={e => set("assigned_to", e.target.value || null)}
                disabled={!canAssignOthers || assignableUsers.length <= 1}
                style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate800, border:`1px solid ${T.slate200}`, borderRadius:8, background:canAssignOthers?T.white:T.slate100, outline:"none", boxSizing:"border-box" }}>
                {assignableUsers.length === 0 && <option value="">— Unassigned —</option>}
                {assignableUsers.map(u => (
                  <option key={u.id} value={u.id}>{u.full_name || u.email}</option>
                ))}
              </select>
            </div>
          </div>
          <label style={{ display:"flex", alignItems:"center", gap:8, fontSize:12, color:T.slate700, cursor:"pointer", padding:"6px 0" }}>
            <input type="checkbox" checked={!!form.in_weekly_focus} onChange={e => set("in_weekly_focus", e.target.checked)} />
            <span>★ Push to this week&rsquo;s to-dos</span>
          </label>
        </div>
        <div style={{ padding:"12px 20px", borderTop:`1px solid ${T.slate200}`, display:"flex", justifyContent:"flex-end", gap:8 }}>
          <button onClick={onCancel} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.slate600, background:T.slate100, border:"none", borderRadius:7, cursor:"pointer" }}>Cancel</button>
          <button onClick={() => form.title.trim() && onSave({
              ...form,
              id:`t${Date.now()}`,
              status:"open",
              created_by:"Jane Smith",
              created_at:"Today",
              parent_task_id: form.parent_task_id || null,
              task_type: form.task_type || "task",
            })}
            disabled={!form.title.trim()}
            style={{ padding:"7px 16px", fontSize:11, fontWeight:600, color:T.white, background:form.title.trim()?T.blue:"#94A3B8", border:"none", borderRadius:7, cursor:form.title.trim()?"pointer":"not-allowed" }}>
            Create {typ.label}
          </button>
        </div>
      </div>
    </div>
  );
};

// ─── Section: This Week's To-Dos ──────────────────────────────
const ToDosSection = ({ tasks, onComplete, onNavigate, onToggleFocus }) => {
  const focusOpen = tasks.filter(t => t.in_weekly_focus && t.status !== "completed");

  const byCat = {};
  for (const t of focusOpen) {
    const k = t.task_category || "_uncategorized";
    (byCat[k] = byCat[k] || []).push(t);
  }
  const orderedKeys = [
    ...TASK_CATEGORY_ORDER.filter(k => byCat[k]),
    ...(byCat._uncategorized ? ["_uncategorized"] : []),
  ];

  const askContext = `My this-week to-dos:\n${focusOpen.map(t => `• [${t.task_category || "uncategorized"}] ${t.title} (${t.priority}, due ${t.due_date || "no date"})`).join("\n")}\n\nHelp me sequence these for the week.`;

  return (
    <div>
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:14, gap:10, flexWrap:"wrap" }}>
        <div>
          <div style={{ fontSize:13, fontWeight:600, color:T.slate800 }}>This week&rsquo;s to-dos</div>
          <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>
            {focusOpen.length} open · star ☆ any task in the Tasks tab to add it here · grouped by category
          </div>
        </div>
        
      </div>

      {focusOpen.length === 0 ? (
        <Card>
          <div style={{ fontSize:13, color:T.slate500, textAlign:"center", padding:"24px 12px" }}>
            Nothing pushed to this week&rsquo;s to-dos yet.<br />
            <span style={{ fontSize:11, color:T.slate400 }}>Open the Tasks tab and tap ☆ on anything you want surfaced here.</span>
          </div>
        </Card>
      ) : orderedKeys.map(key => {
        const cat = TASK_CATEGORIES[key];
        const list = byCat[key];
        return (
          <div key={key} style={{ marginBottom:14 }}>
            <div style={{ display:"flex", alignItems:"center", gap:8, marginBottom:6 }}>
              <span style={{ fontSize:12, fontWeight:700, color:cat?cat.color:T.slate500 }}>
                {cat ? `${cat.icon} ${cat.label}` : "Uncategorized"}
              </span>
              <span style={{ fontSize:10, color:T.slate400 }}>({list.length})</span>
            </div>
            <div style={{ display:"flex", flexDirection:"column", gap:4 }}>
              {list.map(task => (
                <TaskCard key={task.id} task={task} onComplete={onComplete} onNavigate={onNavigate} onToggleFocus={onToggleFocus} />
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
};

// ─── Section: Tasks List ──────────────────────────────────────
const TasksList = ({ tasks, onComplete, onNavigate, onAdd, onToggleFocus, userRole, userId, adminUsers = [] }) => {
  const isOwner = userRole === "owner";
  // Owner picks All / Mine / each other admin. Managers see only own via RLS; chips hidden.
  const [assigneeFilter, setAssigneeFilter] = useState("all");
  const [filter,     setFilter]     = useState("open");
  const [priority,   setPriority]   = useState("all");
  const [taskCat,    setTaskCat]    = useState("all");
  const [typeFilter, setTypeFilter] = useState("all");          // all | epic | story | task
  const viewMode = "nested"; // view mode toggle was removed; nested is the only mode
  // Expanded epics/stories. Default = ALL COLLAPSED (empty set). Persists across sessions.
  const EXPAND_KEY = "bcc:tg:expanded";
  const [expandedIds, setExpandedIds] = useState(() => {
    try {
      const raw = (typeof window !== "undefined") ? window.localStorage.getItem(EXPAND_KEY) : null;
      return new Set(raw ? JSON.parse(raw) : []);
    } catch { return new Set(); }
  });
  const persistExpanded = (set) => {
    try { window.localStorage.setItem(EXPAND_KEY, JSON.stringify(Array.from(set))); } catch {}
  };
  // Safety net: re-persist whenever the set changes, regardless of how it was changed.
  useEffect(() => {
    try { window.localStorage.setItem(EXPAND_KEY, JSON.stringify(Array.from(expandedIds))); } catch {}
  }, [expandedIds]);
  // Cross-tab sync: pick up changes made in other open tabs.
  useEffect(() => {
    const onStorage = (e) => {
      if (e.key !== EXPAND_KEY) return;
      try { setExpandedIds(new Set(e.newValue ? JSON.parse(e.newValue) : [])); } catch {}
    };
    if (typeof window !== "undefined") {
      window.addEventListener("storage", onStorage);
      return () => window.removeEventListener("storage", onStorage);
    }
  }, []);
  const toggleExpand = (id) => {
    setExpandedIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      persistExpanded(next);
      return next;
    });
  };
  // expandAll/collapseAll removed — per-card chevron is the only expand mechanism.
  const [showModal,  setShowModal]  = useState(false);
  const [newType,    setNewType]    = useState("task");          // type for the "+ New" modal
  const [newParentId, setNewParentId] = useState(null);          // optional preset parent

  const statusPriorityCatPass = (t) => {
    if (filter === "open"        && t.status === "completed")  return false;
    if (filter === "completed"   && t.status !== "completed")  return false;
    if (filter === "in_progress" && t.status !== "in_progress")return false;
    if (priority !== "all" && t.priority !== priority) return false;
    if (taskCat  !== "all" && t.task_category !== taskCat) return false;
    // Assignee scope (owner-only; managers are RLS-scoped to own).
    if (isOwner && assigneeFilter !== "all") {
      if (assigneeFilter === "mine") {
        if (t.assigned_to !== userId) return false;
      } else if (t.assigned_to !== assigneeFilter) {
        return false;
      }
    }
    return true;
  };

  // Flat filtered list — used by typeFilter="all" + flat view + counts
  const filtered = useMemo(() => tasks.filter(t => {
    if (!statusPriorityCatPass(t)) return false;
    if (typeFilter !== "all" && (t.task_type || "task") !== typeFilter) return false;
    return true;
  }), [tasks, filter, priority, taskCat, typeFilter, assigneeFilter, isOwner, userId]);

  // Hierarchy ordering for nested view.
  // For an epic, include the epic + all its descendant stories + tasks (limited to 2 levels deep).
  // Orphan stories (parent not present or null) render at root. Orphan tasks too.
  const nestedRows = useMemo(() => {
    if (viewMode !== "nested") return null;
    const pass = (t) => statusPriorityCatPass(t);
    const passType = (t) => typeFilter === "all" || (t.task_type || "task") === typeFilter;
    const rows = [];
    const seen = new Set();
    // Epics first
    const epics = tasks.filter(t => (t.task_type === "epic") && pass(t)).sort((a,b) => (a.title||"").localeCompare(b.title||""));
    for (const e of epics) {
      // If filtering by a child type, only show epic when it has matching descendants
      if (typeFilter !== "all" && typeFilter !== "epic") {
        const hasMatch = tasks.some(t => t.parent_task_id === e.id && passType(t) && pass(t))
          || tasks.some(t => {
              const p = tasks.find(p => p.id === t.parent_task_id);
              return p && p.parent_task_id === e.id && passType(t) && pass(t);
            });
        if (!hasMatch) continue;
      } else if (!passType(e)) continue;
      rows.push({ task:e, depth:0 });
      seen.add(e.id);
      // Epic not expanded → mark every descendant as seen so they don't fall to the orphan bucket.
      if (!expandedIds.has(e.id)) {
        const q = [e.id];
        while (q.length) {
          const pid = q.shift();
          for (const t of tasks) {
            if (t.parent_task_id === pid) { seen.add(t.id); q.push(t.id); }
          }
        }
        continue;
      }
      // Epic expanded → render its direct stories + direct tasks. Stories drill down further only if they too are expanded.
      const stories = tasks.filter(t => t.parent_task_id === e.id && t.task_type === "story" && pass(t))
        .sort((a,b) => (a.title||"").localeCompare(b.title||""));
      for (const s of stories) {
        if (typeFilter === "all" || typeFilter === "story" || typeFilter === "task") {
          rows.push({ task:s, depth:1 });
          seen.add(s.id);
        }
        if (!expandedIds.has(s.id)) {
          // Story not expanded → mark its tasks as seen, skip rendering them.
          for (const t of tasks) {
            if (t.parent_task_id === s.id) seen.add(t.id);
          }
          continue;
        }
        const grand = tasks.filter(t => t.parent_task_id === s.id && pass(t))
          .sort((a,b) => (a.title||"").localeCompare(b.title||""));
        for (const g of grand) {
          if (typeFilter === "all" || typeFilter === (g.task_type || "task")) {
            rows.push({ task:g, depth:2 });
            seen.add(g.id);
          }
        }
      }
      const directTasks = tasks.filter(t => t.parent_task_id === e.id && t.task_type !== "story" && pass(t))
        .sort((a,b) => (a.title||"").localeCompare(b.title||""));
      for (const dt of directTasks) {
        if (typeFilter === "all" || typeFilter === (dt.task_type || "task")) {
          rows.push({ task:dt, depth:1 });
          seen.add(dt.id);
        }
      }
    }
    // Orphans — anything not already rendered and not under an in-view epic
    const orphans = tasks.filter(t => !seen.has(t.id) && pass(t) && passType(t))
      .sort((a,b) => {
        // Stories first, then tasks
        const ar = a.task_type === "story" ? 0 : 1;
        const br = b.task_type === "story" ? 0 : 1;
        if (ar !== br) return ar - br;
        return (a.title||"").localeCompare(b.title||"");
      });
    for (const o of orphans) rows.push({ task:o, depth:0 });
    return rows;
  }, [tasks, filter, priority, taskCat, typeFilter, viewMode, expandedIds, assigneeFilter, isOwner, userId]);

  return (
    <div>
      {/* Toolbar */}
      <div style={{ display:"flex", gap:8, marginBottom:16, flexWrap:"wrap", alignItems:"center" }}>
        <div style={{ display:"flex", gap:2, background:T.slate100, borderRadius:8, padding:3 }}>
          {[{id:"open",label:"Open"},{id:"in_progress",label:"In Progress"},{id:"completed",label:"Completed"}].map(f => (
            <button key={f.id} onClick={() => setFilter(f.id)} style={{ padding:"6px 12px", fontSize:11, fontWeight:filter===f.id?600:400, color:filter===f.id?T.slate900:T.slate500, background:filter===f.id?T.white:"transparent", border:"none", borderRadius:6, cursor:"pointer", boxShadow:filter===f.id?"0 1px 3px rgba(0,0,0,0.08)":"none" }}>
              {f.label} ({tasks.filter(t => f.id==="open"?t.status==="open":f.id==="in_progress"?t.status==="in_progress":t.status==="completed").length})
            </button>
          ))}
        </div>
        <select value={priority} onChange={e => setPriority(e.target.value)} style={{ padding:"7px 10px", fontSize:11, color:T.slate700, border:`1px solid ${T.slate200}`, borderRadius:7, background:T.white, outline:"none" }}>
          <option value="all">All Priority</option>
          {Object.keys(PRIORITY).map(p => <option key={p} value={p}>{PRIORITY[p].label}</option>)}
        </select>
<div style={{ flex:1 }} />
        {/* "+ New" — pick type inside the modal */}
        <button onClick={() => { setNewType("task"); setNewParentId(null); setShowModal(true); }} title="New item"
          style={{ display:"flex", alignItems:"center", gap:6, padding:"7px 14px", fontSize:11, fontWeight:600, color:T.white, background:T.blue, border:"none", borderRadius:8, cursor:"pointer", boxShadow:"0 1px 3px rgba(0,0,0,0.1)" }}>
          + New
        </button>
        
      </div>

      {/* Assignee filter chips — owner-only, shown when 2+ admins exist.
          Manager sees only own tasks via RLS, so chips are hidden for them. */}
      {isOwner && adminUsers.length > 1 && (
        <div style={{ display:"flex", gap:6, marginBottom:10, overflowX:"auto", WebkitOverflowScrolling:"touch", paddingBottom:4 }}>
          {[
            { key:"all",  label:"All",  count: tasks.length },
            { key:"mine", label:"Mine", count: tasks.filter(t => t.assigned_to === userId).length },
            ...adminUsers
              .filter(u => u.id !== userId)
              .map(u => ({ key: u.id, label: (u.full_name || u.email || "Unknown").split(" ")[0], count: tasks.filter(t => t.assigned_to === u.id).length })),
          ].map(c => {
            const active = assigneeFilter === c.key;
            return (
              <button key={c.key} onClick={() => setAssigneeFilter(c.key)}
                style={{
                  flexShrink:0, whiteSpace:"nowrap",
                  display:"inline-flex", alignItems:"center", gap:5,
                  padding:"6px 11px", fontSize:11, fontWeight: active ? 700 : 500,
                  color: active ? T.white : T.slate700,
                  background: active ? T.blue : T.slate100,
                  border: active ? `1px solid ${T.blue}` : `1px solid ${T.slate200}`,
                  borderRadius:18, cursor:"pointer", transition:"all 0.12s",
                }}>
                <span>{c.label}</span>
                <span style={{ fontSize:10, fontWeight:600, padding:"1px 6px", borderRadius:10,
                  background: active ? "rgba(255,255,255,0.25)" : T.white,
                  color: active ? T.white : T.slate600 }}>{c.count}</span>
              </button>
            );
          })}
        </div>
      )}

      {/* Category chips — one tap to filter; horizontal scroll on phone */}
      <div style={{ display:"flex", gap:6, marginBottom:14, overflowX:"auto", WebkitOverflowScrolling:"touch", paddingBottom:4 }}>
        {(() => {
          const baseFiltered = tasks.filter(t => {
            if (filter === "open"        && t.status === "completed")  return false;
            if (filter === "completed"   && t.status !== "completed")  return false;
            if (filter === "in_progress" && t.status !== "in_progress")return false;
            if (priority !== "all" && t.priority !== priority) return false;
            return true;
          });
          const counts = { all: baseFiltered.length };
          for (const k of TASK_CATEGORY_ORDER) counts[k] = baseFiltered.filter(t => t.task_category === k).length;
          const chips = [{ key:"all", label:"All", icon:"", color:T.slate700 },
                         ...TASK_CATEGORY_ORDER.map(k => ({ key:k, ...TASK_CATEGORIES[k] }))];
          return chips.map(c => {
            const active = taskCat === c.key;
            const n = counts[c.key] || 0;
            return (
              <button key={c.key} onClick={() => setTaskCat(c.key)}
                style={{
                  flexShrink:0, whiteSpace:"nowrap",
                  display:"inline-flex", alignItems:"center", gap:5,
                  padding:"6px 11px", fontSize:11, fontWeight:active?700:500,
                  color: active ? T.white : c.color,
                  background: active ? c.color : (c.color === T.slate700 ? T.slate100 : c.color + "15"),
                  border: active ? `1px solid ${c.color}` : `1px solid ${c.color === T.slate700 ? T.slate200 : c.color + "30"}`,
                  borderRadius:18, cursor:"pointer", transition:"all 0.12s",
                }}>
                {c.icon && <span>{c.icon}</span>}
                <span>{c.label}</span>
                <span style={{ fontSize:10, fontWeight:600, padding:"1px 6px", borderRadius:10,
                  background: active ? "rgba(255,255,255,0.25)" : T.white,
                  color: active ? T.white : (c.color === T.slate700 ? T.slate600 : c.color) }}>{n}</span>
              </button>
            );
          });
        })()}
      </div>

      {/* Task List */}
      <div style={{ display:"flex", flexDirection:"column", gap:4 }}>
        {(viewMode === "nested" ? (nestedRows || []).length : filtered.length) === 0 ? (
          <div style={{ textAlign:"center", padding:"40px 20px", color:T.slate400, fontSize:13 }}>
            No tasks match your current filters.
          </div>
        ) : viewMode === "nested" ? (
          (nestedRows || []).map(({ task, depth }) => (
            <TaskCard key={task.id} task={task} allTasks={tasks} depth={depth}
              onComplete={onComplete} onNavigate={onNavigate} onToggleFocus={onToggleFocus}
              isExpanded={expandedIds.has(task.id)}
              onToggleExpand={toggleExpand} />
          ))
        ) : (
          filtered.map(task => (
            <TaskCard key={task.id} task={task} allTasks={tasks} depth={0}
              onComplete={onComplete} onNavigate={onNavigate} onToggleFocus={onToggleFocus} />
          ))
        )}
      </div>

      {showModal && (
        <NewTaskModal
          allTasks={tasks}
          defaultType={newType}
          defaultParentId={newParentId}
          adminUsers={adminUsers}
          currentUserId={userId}
          currentUserRole={userRole}
          onSave={(task) => { onAdd(task); setShowModal(false); }}
          onCancel={() => setShowModal(false)}
        />
      )}
    </div>
  );
};

// ─── Section: Goals ───────────────────────────────────────────
const GoalsSection = ({ goals }) => {
  const [expanded, setExpanded] = useState(null);

  return (
    <div>
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:16 }}>
        <div style={{ fontSize:13, color:T.slate500 }}>
          Track your agency goals and progress toward each target for {new Date().getFullYear()}.
        </div>
        
      </div>

      <div style={{ display:"flex", flexDirection:"column", gap:10 }}>
        {goals.map(goal => {
          const cat = GOAL_CATS[goal.category] || GOAL_CATS.personal;
          const p = pct(goal.current_value, goal.target_value);
          const onTrack = p >= 40;
          const isExpanded = expanded === goal.id;

          return (
            <div key={goal.id} style={{ background:T.white, border:`1px solid ${isExpanded?T.blue:T.slate200}`, borderRadius:12, overflow:"hidden" }}>
              <div style={{ padding:"16px 18px", cursor:"pointer" }} onClick={() => setExpanded(isExpanded?null:goal.id)}>
                <div style={{ display:"flex", alignItems:"flex-start", justifyContent:"space-between", gap:12, marginBottom:10 }}>
                  <div style={{ display:"flex", alignItems:"center", gap:10 }}>
                    <div style={{ width:36, height:36, borderRadius:10, background:cat.color+"20", display:"flex", alignItems:"center", justifyContent:"center", fontSize:18, flexShrink:0 }}>
                      {cat.icon}
                    </div>
                    <div>
                      <div style={{ fontSize:14, fontWeight:700, color:T.slate900, letterSpacing:"-0.01em" }}>{goal.title}</div>
                      <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>{goal.description} · Due {goal.target_date}</div>
                    </div>
                  </div>
                  <div style={{ display:"flex", alignItems:"center", gap:10, flexShrink:0 }}>
                    <div style={{ textAlign:"right" }}>
                      <div style={{ fontSize:22, fontWeight:700, color:onTrack?T.green:T.amber, letterSpacing:"-0.02em" }}>{p}%</div>
                      <div style={{ fontSize:10, color:T.slate400 }}>{fmt(goal.current_value,goal.unit)} / {fmt(goal.target_value,goal.unit)}</div>
                    </div>
                    <span style={{ fontSize:9, fontWeight:600, padding:"3px 8px", borderRadius:20, background:onTrack?T.greenLt:T.amberLt, color:onTrack?"#065F46":"#92400E" }}>
                      {onTrack?"On track":"Needs focus"}
                    </span>
                    <span style={{ color:T.slate400, fontSize:12 }}>{isExpanded?"▲":"▼"}</span>
                  </div>
                </div>

                <ProgressBar value={goal.current_value} max={goal.target_value} color={onTrack?T.green:T.amber} height={10} />

                {/* Monthly bars for dollar goals */}
                {goal.monthly_data && (
                  <div style={{ display:"flex", gap:3, height:32, alignItems:"flex-end", marginTop:10 }}>
                    {(Array.isArray(goal.monthly_data) ? goal.monthly_data : []).map((v, i) => {
                      const maxM = (Array.isArray(goal.monthly_data) && goal.monthly_data.length > 0 ? Math.max(...goal.monthly_data.filter(x=>x>0), 0) : 0);
                      return (
                        <div key={i} style={{ flex:1, display:"flex", flexDirection:"column", alignItems:"center", gap:2 }}>
                          <div style={{ width:"100%", background:v>0?T.blue:T.slate100, borderRadius:"2px 2px 0 0", height:v>0?`${Math.max(6,(v/maxM)*28)}px`:"3px" }} />
                          <div style={{ fontSize:7, color:T.slate400 }}>
                            {["J","F","M","A","M","J","J","A","S","O","N","D"][i]}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>

              {isExpanded && (
                <div style={{ padding:"0 18px 16px", borderTop:`1px solid ${T.slate100}` }}>
                  <div style={{ fontSize:12, color:T.slate600, lineHeight:1.7, marginTop:10, marginBottom:10 }}>
                    {goal.notes}
                  </div>
                  
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
};

// ─── Section: Completed ───────────────────────────────────────
const CompletedSection = ({ tasks }) => {
  const completed = tasks.filter(t => t.status === "completed");
  return (
    <Card>
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:14 }}>
        <div>
          <div style={{ fontSize:13, fontWeight:600, color:T.slate800 }}>Completed tasks</div>
          <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>{completed.length} tasks completed this month — great work</div>
        </div>
      </div>
      <div style={{ display:"flex", flexDirection:"column", gap:4 }}>
        {completed.map((task,i) => {
          const pr = PRIORITY[task.priority] || PRIORITY.medium;
          const cat = categoryConfig(task.task_category);
          return (
            <div key={task.id} style={{ display:"flex", alignItems:"center", gap:10, padding:"9px 0", borderBottom:i<completed.length-1?`1px solid ${T.slate100}`:"none", opacity:0.7 }}>
              <div style={{ width:18, height:18, borderRadius:4, background:T.green, display:"flex", alignItems:"center", justifyContent:"center", flexShrink:0 }}>
                <span style={{ color:T.white, fontSize:10 }}>✓</span>
              </div>
              <div style={{ flex:1, minWidth:0 }}>
                <div style={{ fontSize:12, color:T.slate600, textDecoration:"line-through", overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap" }}>{task.title}</div>
                <div style={{ fontSize:10, color:T.slate400, marginTop:1 }}>{cat ? `${cat.icon} ${cat.label} · ` : ""}Completed {task.completed_at}</div>
              </div>
              <span style={{ fontSize:9, fontWeight:600, padding:"2px 7px", borderRadius:20, background:pr.bg, color:pr.color, flexShrink:0 }}>{pr.label}</span>
            </div>
          );
        })}
      </div>
    </Card>
  );
};

// ─── Main Tasks & Goals Module ────────────────────────────────
export default function TasksGoals({ onNavigate, userRole, userId }) {
  const [section,  setSection]  = useState("todos");
  const { data: liveTasks, loading: tasksLoading } = useSupabaseTable("tasks", AGENCY_ID, { orderBy: "due_date", ascending: true });
  const { data: liveGoals, loading: goalsLoading } = useSupabaseTable("goals", AGENCY_ID, { orderBy: "target_date", ascending: true });
  const useMockData = import.meta.env.VITE_USE_MOCK_DATA !== "false";

  // Admin users (owner + manager) — assignee dropdown source + UUID→name lookup.
  // Per-admin task scoping (migration 043): owner sees all, manager only own (RLS).
  const [adminUsers, setAdminUsers] = useState([]);
  useEffect(() => {
    if (!supabase) return;
    let cancelled = false;
    (async () => {
      const { data, error } = await supabase
        .from("users")
        .select("id, full_name, email, role")
        .eq("agency_id", AGENCY_ID)
        .in("role", ["owner", "manager"])
        .eq("is_active", true)
        .order("role", { ascending: true });
      if (cancelled) return;
      if (error) { console.error("[TasksGoals] adminUsers load failed:", error); return; }
      setAdminUsers(data || []);
    })();
    return () => { cancelled = true; };
  }, []);

  const [tasks, setTasks] = useState(useMockData ? MOCK_TASKS : []);
  useEffect(() => {
    if (liveTasks && liveTasks.length > 0) {
      // Alias schema fields so existing render code (task.due_date, task.completed_at, etc.) keeps working.
      // IMPORTANT: the DB status vocabulary is open/closed; this module's render
      // code checks for "completed"/"in_progress". Normalize here at the source so
      // counts, the Completed tab, the Open filter, and badges all stay consistent.
      const normStatus = (s) => {
        const v = (s || "").toLowerCase();
        if (["closed","done","complete","completed"].includes(v)) return "completed";
        if (["in_progress","in progress","active","doing"].includes(v)) return "in_progress";
        return "open";
      };
      setTasks(liveTasks.map(t => ({
        ...t,
        status:         normStatus(t.status),
        task_category:  t.task_category || null,
        task_type:      t.task_type || "task",
        parent_task_id: t.parent_task_id || null,
        in_weekly_focus:!!t.in_weekly_focus,
        due_date:       t.due_date ? new Date(t.due_date).toLocaleDateString("en-US",{month:"short",day:"numeric",year:"numeric"}) : "",
        completed_at:   t.completed_at ? new Date(t.completed_at).toLocaleDateString("en-US",{month:"short",day:"numeric",year:"numeric"}) : "",
      })));
    }
  }, [liveTasks]);

  const goals = (liveGoals && liveGoals.length > 0)
    ? liveGoals
    : useMockData ? MOCK_GOALS : [];

  // Resolve assigned_to UUIDs to display names. Falls through to raw value when
  // adminUsers hasn't loaded yet (mock data still renders).
  const tasksWithDisplay = useMemo(() => {
    if (!adminUsers || adminUsers.length === 0) return tasks;
    const nameById = new Map(adminUsers.map(u => [u.id, u.full_name || u.email || "Unknown"]));
    return tasks.map(t => ({
      ...t,
      assigned_to_name: t.assigned_to ? (nameById.get(t.assigned_to) || t.assigned_to) : null,
    }));
  }, [tasks, adminUsers]);

  if (tasksLoading || goalsLoading) return <div style={{padding:40,textAlign:"center",fontSize:13,color:"#64748B"}}>Loading tasks and goals…</div>;
  if (tasks.length === 0 && goals.length === 0) return <EmptyState module="tasks" />;

  const completeTask = async (id) => {
    // Optimistic UI: flip to completed locally.
    const prevSnapshot = tasks;
    setTasks(prev => prev.map(t => t.id === id
      ? { ...t, status:"completed", completed_at:new Date().toLocaleDateString("en-US",{month:"short",day:"numeric",year:"numeric"}) }
      : t
    ));
    // Persist to Supabase (DB status vocabulary is 'closed').
    if (supabase && typeof id === "string") {
      const { error } = await supabase
        .from("tasks")
        .update({ status:"closed", completed_at:new Date().toISOString() })
        .eq("id", id)
        .eq("agency_id", AGENCY_ID);
      if (error) { console.error("[TasksGoals] completeTask failed:", error); setTasks(prevSnapshot); }
    }
  };

  const addTask = async (taskFromModal) => {
    // Persist to Supabase first when running on live data, then update local state.
    const dueIso = (() => {
      if (!taskFromModal.due_date) return null;
      const d = new Date(taskFromModal.due_date);
      return Number.isFinite(d.getTime()) ? d.toISOString().slice(0,10) : null;
    })();
    const payload = {
      agency_id:        AGENCY_ID,
      title:            taskFromModal.title,
      description:      taskFromModal.description || null,
      priority:         taskFromModal.priority || "medium",
      status:           "open",
      task_category:    taskFromModal.task_category || null,
      task_type:        taskFromModal.task_type || "task",
      parent_task_id:   taskFromModal.parent_task_id || null,
      in_weekly_focus:  !!taskFromModal.in_weekly_focus,
      due_date:         dueIso,
      assigned_to:      taskFromModal.assigned_to || userId || null,
      created_by:       "BCC user",
    };
    if (supabase && !useMockData) {
      const { data, error } = await supabase.from("tasks").insert(payload).select().maybeSingle();
      if (error) { console.error("[TasksGoals] addTask insert failed:", error); return; }
      if (data) {
        setTasks(prev => [{
          ...data,
          status:         "open",
          task_category:  data.task_category || null,
          task_type:      data.task_type || "task",
          parent_task_id: data.parent_task_id || null,
          in_weekly_focus:!!data.in_weekly_focus,
          due_date:       data.due_date ? new Date(data.due_date).toLocaleDateString("en-US",{month:"short",day:"numeric",year:"numeric"}) : "",
        }, ...prev]);
        return;
      }
    }
    // Mock fallback
    setTasks(prev => [{ ...taskFromModal, status:"open" }, ...prev]);
  };

  const toggleFocus = async (id, next) => {
    const prevSnapshot = tasks;
    setTasks(prev => prev.map(t => t.id === id ? { ...t, in_weekly_focus: !!next } : t));
    if (supabase && typeof id === "string") {
      const { error } = await supabase
        .from("tasks")
        .update({ in_weekly_focus: !!next })
        .eq("id", id)
        .eq("agency_id", AGENCY_ID);
      if (error) { console.error("[TasksGoals] toggleFocus failed:", error); setTasks(prevSnapshot); }
    }
  };

  const focusCount = tasks.filter(t => t.in_weekly_focus && t.status !== "completed").length;

  const sections = [
    { id:"todos",     label:`To-Dos${focusCount?` (${focusCount})`:""}` },
    { id:"overview",  label:"Overview"                   },
    { id:"goals",     label:"Goals"                      },
    { id:"completed", label:"Completed"                  },
  ];

  return (
    <div>
      {/* Module Header */}
      <div style={{ display:"flex", alignItems:"flex-start", justifyContent:"space-between", marginBottom:16, flexWrap:"wrap", gap:10 }}>
        <div>
          <div style={{ fontSize:20, fontWeight:700, color:T.slate900, letterSpacing:"-0.02em" }}>Tasks & Goals</div>
          <div style={{ fontSize:12, color:T.slate500, marginTop:3 }}>
            {tasks.filter(t=>t.status!=="completed").length} open tasks · {goals.length} active goals · {tasks.filter(t=>t.status==="completed").length} completed this month
          </div>
        </div>
        
      </div>

      {/* Section Navigation */}
      <div style={{ display:"flex", gap:2, flexWrap:"wrap", background:T.slate100, borderRadius:10, padding:4, marginBottom:18 }}>
        {sections.map(s => (
          <button key={s.id} onClick={() => setSection(s.id)} style={{ padding:"7px 14px", fontSize:12, fontWeight:section===s.id?600:400, color:section===s.id?T.slate900:T.slate500, background:section===s.id?T.white:"transparent", border:"none", borderRadius:7, cursor:"pointer", transition:"all 0.12s", boxShadow:section===s.id?"0 1px 3px rgba(0,0,0,0.08)":"none" }}>
            {s.label}
          </button>
        ))}
      </div>

      {/* Section Content */}
      {section === "todos"     && <ToDosSection  tasks={tasksWithDisplay} onComplete={completeTask} onNavigate={onNavigate||(()=>{})} onToggleFocus={toggleFocus} />}
      {section === "overview"  && <TasksList     tasks={tasksWithDisplay} onComplete={completeTask} onNavigate={onNavigate||(() =>{})} onAdd={addTask} onToggleFocus={toggleFocus} userRole={userRole} userId={userId} adminUsers={adminUsers} />}
      {section === "goals"     && <GoalsSection  goals={goals} />}
      {section === "completed" && <CompletedSection tasks={tasksWithDisplay} />}
    </div>
  );
}

