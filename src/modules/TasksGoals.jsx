import { useState, useMemo, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useSupabaseTable } from "../lib/hooks.js";
import EmptyState from "../components/EmptyState.jsx";

// ============================================================
// BCC TASKS & GOALS MODULE v1.1
// Business Command Center — State Farm Agent Edition
// Built by Imaginary Farms LLC · imaginary-farms.com
//
// SECTIONS:
//   1. Overview    — Quick wins, due today, goal progress summary
//   2. This Week   — Tasks pushed to the current week's to-dos
//   3. Tasks       — Full task list, create, filter, complete
//   4. Goals       — Annual goals with progress tracking
//   5. Completed   — History of completed tasks
//
// KEY FEATURES:
//   • Tasks categorized by working area (web app, admin, marketing,
//     training, handbook, playbook)
//   • Per-task "Push to this week's to-dos" toggle drives the
//     This Week tab — survives reloads via tasks.in_weekly_focus
//   • Priority system: critical / high / medium / low
//   • Tasks created by agent, Claude, or automations
//   • Goals track revenue, AIPP, team, compliance, personal
//   • Everything tied to agency_id in Supabase
//
// DATA: Reads tasks, goals tables in Supabase.
//       tasks.task_category + tasks.in_weekly_focus drive the
//       categorization + weekly-focus features (migration
//       tasks_add_category_and_weekly_focus).
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
// Backed by tasks.task_category column (check-constrained to these 6 keys).
// Stable display order — keep keys in lockstep with the DB CHECK constraint.
const TASK_CATEGORIES = {
  web_app:   { label:"Web App",   color:T.blue,    icon:"💻" },
  admin:     { label:"Admin",     color:T.slate500,icon:"📋" },
  marketing: { label:"Marketing", color:T.purple,  icon:"📣" },
  training:  { label:"Training",  color:T.teal,    icon:"🎓" },
  handbook:  { label:"Handbook",  color:T.green,   icon:"📘" },
  playbook:  { label:"Playbook",  color:T.amber,   icon:"📖" },
};
const CATEGORY_ORDER = ["web_app","admin","marketing","training","handbook","playbook"];

// Defensive lookup; unknown / null categories render as Uncategorized.
const UNCATEGORIZED = { label:"Uncategorized", color:T.slate400, icon:"·" };
const categoryConfig = (key) => TASK_CATEGORIES[key] || UNCATEGORIZED;

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
// Production gates mocks via VITE_USE_MOCK_DATA="false". Live data wins.
const MOCK_TASKS = [
  { id:"t1", title:"Review compensation pool ramp through Phase 1", priority:"high",   status:"open", task_category:"admin",    in_weekly_focus:true,  due_date:"Jul 4, 2026",  assigned_to:null, created_by:"system", description:"Walk through the residual-pool comp schedule before 7/11 rollout.",       created_at:"Jun 28" },
  { id:"t2", title:"Fix CPR detail responsive layout on phone",     priority:"medium", status:"open", task_category:"web_app",  in_weekly_focus:true,  due_date:"Jul 2, 2026",  assigned_to:null, created_by:"system", description:"Module-specific font-size tightening still pending from 06-22 sweep.",   created_at:"Jun 25" },
  { id:"t3", title:"Update Handbook policy on time-off requests",   priority:"low",    status:"open", task_category:"handbook", in_weekly_focus:false, due_date:"Jul 18, 2026", assigned_to:null, created_by:"system", description:"Reflect new voting + decision-email flow.",                                  created_at:"Jun 22" },
];

const MOCK_GOALS = [
  { id:"g1", title:"+25% P&C Premium",        target_value:25, current_value:14, category:"revenue",    unit:"percentage", target_date:"Dec 31, 2026", status:"active", notes:"On-time pace tracking under target — Auto premium growth pacing slower than Fire." },
  { id:"g2", title:"Champions Circle 2026",   target_value:400,current_value:118, category:"growth",     unit:"count",      target_date:"Dec 31, 2026", status:"active", notes:"FS Credits bucket is the gap; Life production is highest leverage." },
  { id:"g3", title:"+1 pt Owner Profit / Q",  target_value:4,  current_value:1,  category:"revenue",    unit:"count",      target_date:"Dec 31, 2026", status:"active", notes:"Q1 came in flat; Q2 trending up." },
];

// ─── Date / Format Helpers ────────────────────────────────────
const parseDueDate = (s) => {
  if (!s) return null;
  const d = new Date(s);
  return isNaN(d) ? null : d;
};
const daysUntil = (s) => {
  const d = parseDueDate(s);
  if (!d) return Infinity;
  const today = new Date(); today.setHours(0,0,0,0);
  const target = new Date(d); target.setHours(0,0,0,0);
  return Math.round((target - today) / 86400000);
};
const isOverdue = (s) => {
  const n = daysUntil(s);
  return Number.isFinite(n) && n < 0;
};
const fmt = (v, unit) => {
  if (v == null) return "—";
  if (unit === "dollars")    return `$${Number(v).toLocaleString()}`;
  if (unit === "percentage") return `${Number(v).toFixed(1)}%`;
  return Number(v).toLocaleString();
};
const pct = (cur, tgt) => {
  const c = Number(cur), t = Number(tgt);
  if (!Number.isFinite(c) || !Number.isFinite(t) || t === 0) return 0;
  return Math.max(0, Math.min(999, Math.round((c/t)*100)));
};

// ─── Shared UI Bits ───────────────────────────────────────────
const Card = ({ children, style }) => (
  <div style={{ background:T.white, border:`1px solid ${T.slate200}`, borderRadius:12, padding:16, ...(style||{}) }}>
    {children}
  </div>
);

const AskBtn = ({ context, size }) => (
  <button
    onClick={() => { navigator.clipboard?.writeText(context); window.open("https://claude.ai","_blank"); }}
    style={{ display:"flex", alignItems:"center", gap:5, background:T.blue, color:T.white, border:"none", borderRadius:7, padding:size==="small"?"5px 10px":"7px 13px", fontSize:size==="small"?10:11, fontWeight:600, cursor:"pointer", whiteSpace:"nowrap", flexShrink:0 }}
  >⚡ Ask Claude</button>
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
const TaskCard = ({ task, onComplete, onNavigate, onToggleWeekly }) => {
  const [expanded, setExpanded] = useState(false);
  const pr = PRIORITY[task.priority] || PRIORITY.medium;
  const cat = categoryConfig(task.task_category);
  const overdue = task.status === "open" && isOverdue(task.due_date);
  const days = daysUntil(task.due_date);
  const isCompleted = task.status === "completed";
  const inWeek = !!task.in_weekly_focus;

  return (
    <div style={{
      background:T.white,
      border:`1px solid ${expanded?T.blue:overdue?T.red:T.slate200}`,
      borderLeft:`4px solid ${overdue?T.red:pr.color}`,
      borderRadius:10, overflow:"hidden",
      opacity:isCompleted?0.7:1,
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
        <div style={{ flex:1, minWidth:0, cursor:"pointer" }} onClick={() => setExpanded(e => !e)}>
          <div style={{ display:"flex", alignItems:"center", gap:6, marginBottom:3, flexWrap:"wrap" }}>
            <span style={{ fontSize:12, fontWeight:isCompleted?400:600, color:isCompleted?T.slate400:T.slate800, textDecoration:isCompleted?"line-through":"none" }}>
              {task.title}
            </span>
          </div>
          <div style={{ display:"flex", alignItems:"center", gap:8, flexWrap:"wrap" }}>
            <span style={{ fontSize:9, fontWeight:600, padding:"2px 7px", borderRadius:20, background:pr.bg, color:pr.color }}>{pr.label}</span>
            <span style={{ fontSize:9, fontWeight:600, padding:"2px 7px", borderRadius:20, background:cat.color+"20", color:cat.color }}>{cat.icon} {cat.label}</span>
            {inWeek && !isCompleted && (
              <span style={{ fontSize:9, fontWeight:600, padding:"2px 7px", borderRadius:20, background:T.amberLt, color:T.amber, border:`1px solid ${T.amber}40` }}>⭐ This Week</span>
            )}
            <span style={{ fontSize:10, color:overdue?T.red:days<=3?T.amber:T.slate400, fontWeight:overdue||days<=3?600:400 }}>
              {isCompleted ? `Completed ${task.completed_at || ""}` : !task.due_date ? "No due date" : overdue ? `Overdue — ${task.due_date}` : days===0 ? "Due today" : days===1 ? "Due tomorrow" : `Due ${task.due_date}`}
            </span>
            <span style={{ fontSize:9, color:T.slate400, fontStyle:"italic" }}>by {task.created_by || "—"}</span>
          </div>
        </div>

        {/* Actions */}
        {!isCompleted && onToggleWeekly && (
          <button
            onClick={(e) => { e.stopPropagation(); onToggleWeekly(task.id, !inWeek); }}
            style={{ fontSize:10, fontWeight:600, color:inWeek?T.amber:T.slate500, background:inWeek?T.amberLt:T.slate100, border:inWeek?`1px solid ${T.amber}40`:"1px solid transparent", borderRadius:6, padding:"4px 9px", cursor:"pointer", flexShrink:0, whiteSpace:"nowrap" }}
            title={inWeek ? "Remove from This Week" : "Push to This Week"}
          >
            {inWeek ? "⭐ In Week" : "+ This Week"}
          </button>
        )}

        <span style={{ color:T.slate400, fontSize:11, flexShrink:0, cursor:"pointer" }} onClick={() => setExpanded(e => !e)}>
          {expanded ? "▲" : "▼"}
        </span>
      </div>

      {expanded && task.description && (
        <div style={{ padding:"0 12px 12px 46px", borderTop:`1px solid ${T.slate100}` }}>
          <div style={{ fontSize:12, color:T.slate600, lineHeight:1.6, marginTop:8, marginBottom:8 }}>
            {task.description}
          </div>
          <AskBtn size="small" context={`Task context:\nTitle: ${task.title}\nPriority: ${task.priority}\nDue: ${task.due_date}\nCategory: ${cat.label}\nIn weekly focus: ${inWeek}\nDescription: ${task.description}\n\nHelp me think through how to complete this task efficiently.`} />
        </div>
      )}
    </div>
  );
};

// ─── New Task Modal ───────────────────────────────────────────
const NewTaskModal = ({ onSave, onCancel }) => {
  const [form, setForm] = useState({
    title:"",
    description:"",
    priority:"medium",
    task_category:"admin",
    due_date:"",
    in_weekly_focus:false,
  });
  const set = (k, v) => setForm(f => ({ ...f, [k]:v }));

  return (
    <div style={{ position:"fixed", inset:0, background:"rgba(15,23,42,0.5)", display:"flex", alignItems:"center", justifyContent:"center", zIndex:1000, padding:20 }}>
      <div style={{ background:T.white, borderRadius:16, width:"100%", maxWidth:500, boxShadow:"0 20px 60px rgba(0,0,0,0.2)", overflow:"hidden" }}>
        <div style={{ padding:"16px 20px", borderBottom:`1px solid ${T.slate200}`, display:"flex", justifyContent:"space-between", alignItems:"center" }}>
          <span style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>New Task</span>
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
                {CATEGORY_ORDER.map(k => <option key={k} value={k}>{TASK_CATEGORIES[k].icon} {TASK_CATEGORIES[k].label}</option>)}
              </select>
            </div>
            <div>
              <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>DUE DATE</label>
              <input type="date" value={form.due_date} onChange={e => set("due_date", e.target.value)}
                style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate800, border:`1px solid ${T.slate200}`, borderRadius:8, outline:"none", boxSizing:"border-box" }} />
            </div>
          </div>
          <label style={{ display:"flex", alignItems:"center", gap:9, fontSize:12, color:T.slate700, cursor:"pointer", padding:"8px 10px", background:form.in_weekly_focus?T.amberLt:T.slate100, border:`1px solid ${form.in_weekly_focus?T.amber+"40":T.slate200}`, borderRadius:8 }}>
            <input
              type="checkbox"
              checked={form.in_weekly_focus}
              onChange={e => set("in_weekly_focus", e.target.checked)}
              style={{ width:16, height:16, accentColor:T.amber, cursor:"pointer", margin:0 }}
            />
            <span style={{ fontWeight:600 }}>⭐ Push to this week's to-dos</span>
            <span style={{ fontSize:11, color:T.slate500 }}>— shows in the This Week tab</span>
          </label>
        </div>
        <div style={{ padding:"12px 20px", borderTop:`1px solid ${T.slate200}`, display:"flex", justifyContent:"flex-end", gap:8 }}>
          <button onClick={onCancel} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.slate600, background:T.slate100, border:"none", borderRadius:7, cursor:"pointer" }}>Cancel</button>
          <button
            onClick={() => form.title.trim() && onSave({
              title:           form.title.trim(),
              description:     form.description || null,
              priority:        form.priority,
              task_category:   form.task_category,
              due_date:        form.due_date || null,
              in_weekly_focus: !!form.in_weekly_focus,
            })}
            disabled={!form.title.trim()}
            style={{ padding:"7px 16px", fontSize:11, fontWeight:600, color:T.white, background:form.title.trim()?T.blue:"#94A3B8", border:"none", borderRadius:7, cursor:form.title.trim()?"pointer":"not-allowed" }}>
            Create Task
          </button>
        </div>
      </div>
    </div>
  );
};

// ─── Section: Overview ────────────────────────────────────────
const TasksOverview = ({ tasks, goals, onComplete, onNavigate, onToggleWeekly, onJumpToWeek }) => {
  const open       = tasks.filter(t => t.status !== "completed");
  const critical   = open.filter(t => t.priority === "critical");
  const dueThisWeek= open.filter(t => {
    if (!t.due_date) return false;
    const d = daysUntil(t.due_date);
    return Number.isFinite(d) && d <= 7 && d >= -14;
  });
  const overdue    = open.filter(t => isOverdue(t.due_date));
  const inWeek     = open.filter(t => t.in_weekly_focus);
  const completedThisMonth = tasks.filter(t => t.status === "completed").length;

  const topGoals = goals.slice(0, 3);

  return (
    <div>
      {/* KPI Row */}
      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit,minmax(130px,1fr))", gap:10, marginBottom:16 }}>
        {[
          { label:"Open Tasks",         value:open.length,             color:T.blue,  border:T.blue, onClick:null },
          { label:"This Week",          value:inWeek.length,           color:inWeek.length>0?T.amber:T.slate500, border:inWeek.length>0?T.amber:T.slate300, onClick:onJumpToWeek },
          { label:"Critical",           value:critical.length,         color:critical.length>0?T.red:T.green, border:critical.length>0?T.red:T.green, onClick:null },
          { label:"Due (next 7 days)",  value:dueThisWeek.length,      color:dueThisWeek.length>2?T.amber:T.green, border:dueThisWeek.length>2?T.amber:T.green, onClick:null },
          { label:"Overdue",            value:overdue.length,          color:overdue.length>0?T.red:T.green, border:overdue.length>0?T.red:T.green, onClick:null },
          { label:"Completed (Month)",  value:completedThisMonth,      color:T.green, border:T.green, onClick:null },
        ].map(k => (
          <div key={k.label} onClick={k.onClick||undefined} style={{ background:T.white, border:`1px solid ${k.border}33`, borderLeft:`4px solid ${k.border}`, borderRadius:10, padding:"11px 13px", cursor:k.onClick?"pointer":"default" }}>
            <div style={{ fontSize:10, fontWeight:600, color:T.slate500, letterSpacing:"0.04em", marginBottom:3, textTransform:"uppercase" }}>{k.label}</div>
            <div style={{ fontSize:22, fontWeight:700, color:k.color }}>{k.value}</div>
          </div>
        ))}
      </div>

      {/* Top-Of-Mind + Goals */}
      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(280px, 1fr))", gap:14 }}>
        <Card>
          <div style={{ fontSize:13, fontWeight:600, color:T.slate800, marginBottom:10 }}>Top of mind</div>
          {(() => {
            const top = open
              .slice()
              .sort((a,b) => {
                const order = { critical:0, high:1, medium:2, low:3 };
                const pa = order[a.priority] ?? 9;
                const pb = order[b.priority] ?? 9;
                if (pa !== pb) return pa - pb;
                return daysUntil(a.due_date) - daysUntil(b.due_date);
              })
              .slice(0, 5);
            if (top.length === 0) return <div style={{ fontSize:12, color:T.slate400 }}>Nothing open — nice.</div>;
            return top.map(t => (
              <TaskCard key={t.id} task={t} onComplete={onComplete} onNavigate={onNavigate} onToggleWeekly={onToggleWeekly} />
            ));
          })()}
        </Card>
        <Card>
          <div style={{ fontSize:13, fontWeight:600, color:T.slate800, marginBottom:10 }}>Top goals</div>
          {topGoals.map(goal => {
            const p = pct(goal.current_value, goal.target_value);
            const onTrack = p >= 70;
            const c = GOAL_CATS[goal.category] || GOAL_CATS.personal;
            return (
              <div key={goal.id} style={{ marginBottom:12 }}>
                <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:4 }}>
                  <div style={{ fontSize:12, fontWeight:600, color:T.slate800 }}>{c.icon} {goal.title}</div>
                  <div style={{ fontSize:11, fontWeight:600, color:onTrack?T.green:T.amber }}>{p}%</div>
                </div>
                <div style={{ fontSize:11, color:T.slate500, marginBottom:4 }}>
                  {fmt(goal.current_value, goal.unit)} of {fmt(goal.target_value, goal.unit)}
                </div>
                <ProgressBar value={goal.current_value} max={goal.target_value} color={onTrack?T.green:T.amber} height={6} />
              </div>
            );
          })}
        </Card>
      </div>
    </div>
  );
};

// ─── Section: This Week ───────────────────────────────────────
const ThisWeekSection = ({ tasks, onComplete, onNavigate, onToggleWeekly, onJumpToAll }) => {
  const inWeek = (tasks || []).filter(t => t.in_weekly_focus && t.status !== "completed");
  const byCategory = useMemo(() => {
    const buckets = {};
    CATEGORY_ORDER.forEach(k => { buckets[k] = []; });
    buckets.__uncat = [];
    inWeek.forEach(t => {
      const key = TASK_CATEGORIES[t.task_category] ? t.task_category : "__uncat";
      buckets[key].push(t);
    });
    return buckets;
  }, [inWeek]);

  return (
    <div>
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", gap:10, marginBottom:14, flexWrap:"wrap" }}>
        <div>
          <div style={{ fontSize:13, fontWeight:600, color:T.slate800 }}>This week's to-dos</div>
          <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>
            {inWeek.length} task{inWeek.length===1?"":"s"} in focus — push more from the Tasks tab as needed.
          </div>
        </div>
        <div style={{ display:"flex", gap:8, alignItems:"center", flexWrap:"wrap" }}>
          {onJumpToAll && (
            <button onClick={onJumpToAll} style={{ padding:"7px 12px", fontSize:11, fontWeight:600, color:T.slate700, background:T.slate100, border:"none", borderRadius:7, cursor:"pointer" }}>
              Browse all tasks →
            </button>
          )}
          <AskBtn context={`This week's to-dos (${inWeek.length}):\n${inWeek.map(t => `• [${(PRIORITY[t.priority]||PRIORITY.medium).label}] ${t.title} — ${(TASK_CATEGORIES[t.task_category]||UNCATEGORIZED).label}`).join("\n")}\n\nWhat should I tackle first today, and how should I sequence the rest of the week?`} />
        </div>
      </div>

      {inWeek.length === 0 ? (
        <Card style={{ textAlign:"center", padding:"36px 20px" }}>
          <div style={{ fontSize:13, color:T.slate500, marginBottom:6 }}>Nothing in this week's focus yet.</div>
          <div style={{ fontSize:11, color:T.slate400 }}>Open the Tasks tab and use the “+ This Week” button on any task to push it here.</div>
        </Card>
      ) : (
        <div style={{ display:"flex", flexDirection:"column", gap:18 }}>
          {[...CATEGORY_ORDER, "__uncat"].map(key => {
            const list = byCategory[key];
            if (!list || list.length === 0) return null;
            const cat = key === "__uncat" ? UNCATEGORIZED : TASK_CATEGORIES[key];
            return (
              <div key={key}>
                <div style={{ display:"flex", alignItems:"center", gap:7, marginBottom:7 }}>
                  <span style={{ fontSize:11, fontWeight:700, color:cat.color, textTransform:"uppercase", letterSpacing:"0.04em" }}>{cat.icon} {cat.label}</span>
                  <span style={{ fontSize:10, color:T.slate400 }}>· {list.length}</span>
                </div>
                <div style={{ display:"flex", flexDirection:"column", gap:4 }}>
                  {list.map(t => (
                    <TaskCard key={t.id} task={t} onComplete={onComplete} onNavigate={onNavigate} onToggleWeekly={onToggleWeekly} />
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
};

// ─── Section: Tasks List ──────────────────────────────────────
const TasksList = ({ tasks, onComplete, onNavigate, onAdd, onToggleWeekly }) => {
  const [filter,       setFilter]       = useState("open");
  const [priority,     setPriority]     = useState("all");
  const [category,     setCategory]     = useState("all");
  const [weeklyOnly,   setWeeklyOnly]   = useState(false);
  const [showModal,    setShowModal]    = useState(false);

  const filtered = useMemo(() => tasks.filter(t => {
    if (filter === "open"        && t.status === "completed")  return false;
    if (filter === "completed"   && t.status !== "completed")  return false;
    if (filter === "in_progress" && t.status !== "in_progress")return false;
    if (priority !== "all" && t.priority !== priority) return false;
    if (category !== "all" && (t.task_category || "") !== category) return false;
    if (weeklyOnly && !t.in_weekly_focus) return false;
    return true;
  }), [tasks, filter, priority, category, weeklyOnly]);

  return (
    <div>
      {/* Toolbar */}
      <div style={{ display:"flex", gap:8, marginBottom:16, flexWrap:"wrap", alignItems:"center" }}>
        <div style={{ display:"flex", gap:2, background:T.slate100, borderRadius:8, padding:3, overflowX:"auto", whiteSpace:"nowrap" }}>
          {[{id:"open",label:"Open"},{id:"in_progress",label:"In Progress"},{id:"completed",label:"Completed"}].map(f => (
            <button key={f.id} onClick={() => setFilter(f.id)} style={{ padding:"6px 12px", fontSize:11, fontWeight:filter===f.id?600:400, color:filter===f.id?T.slate900:T.slate500, background:filter===f.id?T.white:"transparent", border:"none", borderRadius:6, cursor:"pointer", boxShadow:filter===f.id?"0 1px 3px rgba(0,0,0,0.08)":"none", flexShrink:0 }}>
              {f.label} ({tasks.filter(t => f.id==="open"?t.status==="open":f.id==="in_progress"?t.status==="in_progress":t.status==="completed").length})
            </button>
          ))}
        </div>
        <select value={priority} onChange={e => setPriority(e.target.value)} style={{ padding:"7px 10px", fontSize:11, color:T.slate700, border:`1px solid ${T.slate200}`, borderRadius:7, background:T.white, outline:"none" }}>
          <option value="all">All Priority</option>
          {Object.keys(PRIORITY).map(p => <option key={p} value={p}>{PRIORITY[p].label}</option>)}
        </select>
        <select value={category} onChange={e => setCategory(e.target.value)} style={{ padding:"7px 10px", fontSize:11, color:T.slate700, border:`1px solid ${T.slate200}`, borderRadius:7, background:T.white, outline:"none" }}>
          <option value="all">All Categories</option>
          {CATEGORY_ORDER.map(k => <option key={k} value={k}>{TASK_CATEGORIES[k].icon} {TASK_CATEGORIES[k].label}</option>)}
        </select>
        <label style={{ display:"flex", alignItems:"center", gap:6, fontSize:11, fontWeight:600, color:weeklyOnly?T.amber:T.slate600, background:weeklyOnly?T.amberLt:T.slate100, border:weeklyOnly?`1px solid ${T.amber}40`:"1px solid transparent", borderRadius:7, padding:"6px 10px", cursor:"pointer" }}>
          <input type="checkbox" checked={weeklyOnly} onChange={e => setWeeklyOnly(e.target.checked)} style={{ accentColor:T.amber, margin:0, cursor:"pointer" }} />
          ⭐ This Week only
        </label>
        <div style={{ flex:1 }} />
        <button onClick={() => setShowModal(true)} style={{ display:"flex", alignItems:"center", gap:6, padding:"7px 14px", fontSize:11, fontWeight:600, color:T.white, background:T.blue, border:"none", borderRadius:8, cursor:"pointer", flexShrink:0 }}>
          + New Task
        </button>
        <AskBtn context="Review my open task list and help me prioritize. What should I focus on first today? Are there any tasks I should delegate, defer, or eliminate?" />
      </div>

      {/* Task List */}
      <div style={{ display:"flex", flexDirection:"column", gap:4 }}>
        {filtered.length === 0 ? (
          <div style={{ textAlign:"center", padding:"40px 20px", color:T.slate400, fontSize:13 }}>
            No tasks match your current filters.
          </div>
        ) : filtered.map(task => (
          <TaskCard key={task.id} task={task} onComplete={onComplete} onNavigate={onNavigate} onToggleWeekly={onToggleWeekly} />
        ))}
      </div>

      {showModal && (
        <NewTaskModal
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
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:16, flexWrap:"wrap", gap:10 }}>
        <div style={{ fontSize:13, color:T.slate500 }}>
          Track your agency goals and progress toward each target for {new Date().getFullYear()}.
        </div>
        <AskBtn context={`My full goal progress for 2026:\n${goals.map(g=>`• ${g.title} (${g.category}): ${fmt(g.current_value,g.unit)} of ${fmt(g.target_value,g.unit)} = ${pct(g.current_value,g.target_value)}% — ${g.notes||""}`).join("\n")}\n\nGive me a comprehensive goal review. Which goals are at risk? What specific actions would move the needle most this month?`} />
      </div>

      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(280px, 1fr))", gap:12 }}>
        {goals.map(goal => {
          const p = pct(goal.current_value, goal.target_value);
          const onTrack = p >= 70;
          const cat = GOAL_CATS[goal.category] || GOAL_CATS.personal;
          return (
            <Card key={goal.id}>
              <div style={{ display:"flex", alignItems:"flex-start", gap:8, marginBottom:10 }}>
                <span style={{ fontSize:18 }}>{cat.icon}</span>
                <div style={{ flex:1, minWidth:0 }}>
                  <div style={{ fontSize:13, fontWeight:700, color:T.slate900 }}>{goal.title}</div>
                  <div style={{ fontSize:10, color:T.slate400, marginTop:2, textTransform:"uppercase", letterSpacing:"0.04em" }}>{cat.label} · target {goal.target_date}</div>
                </div>
                <div style={{ fontSize:14, fontWeight:700, color:onTrack?T.green:T.amber }}>{p}%</div>
              </div>
              <div style={{ display:"flex", justifyContent:"space-between", fontSize:11, color:T.slate500, marginBottom:4 }}>
                <span>{fmt(goal.current_value, goal.unit)}</span>
                <span>of {fmt(goal.target_value, goal.unit)}</span>
              </div>
              <ProgressBar value={goal.current_value} max={goal.target_value} color={onTrack?T.green:T.amber} height={8} />
              {goal.notes && (
                <div style={{ fontSize:11, color:T.slate500, marginTop:9, lineHeight:1.5 }}>{goal.notes}</div>
              )}
              <div style={{ marginTop:10 }}>
                <AskBtn size="small" context={`Goal deep dive:\nTitle: ${goal.title}\nCategory: ${goal.category}\nTarget: ${fmt(goal.target_value,goal.unit)}\nCurrent: ${fmt(goal.current_value,goal.unit)}\nProgress: ${p}%\nDue: ${goal.target_date}\nNotes: ${goal.notes||""}\n\nHelp me build a specific action plan to hit this goal. What do I need to do this month?`} />
              </div>
            </Card>
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
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:14, flexWrap:"wrap", gap:10 }}>
        <div>
          <div style={{ fontSize:13, fontWeight:600, color:T.slate800 }}>Completed tasks</div>
          <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>{completed.length} task{completed.length===1?"":"s"} completed — great work</div>
        </div>
      </div>
      {completed.length === 0 ? (
        <div style={{ fontSize:12, color:T.slate400, padding:"12px 0" }}>Nothing completed yet.</div>
      ) : (
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
                  <div style={{ fontSize:10, color:T.slate400, marginTop:1 }}>{cat.icon} {cat.label} · Completed {task.completed_at || ""}</div>
                </div>
                <span style={{ fontSize:9, fontWeight:600, padding:"2px 7px", borderRadius:20, background:pr.bg, color:pr.color, flexShrink:0 }}>{pr.label}</span>
              </div>
            );
          })}
        </div>
      )}
    </Card>
  );
};

// ─── Normalize a DB task row into the shape this module renders ─
const normStatus = (s) => {
  const v = (s || "").toLowerCase();
  if (["closed","done","complete","completed"].includes(v)) return "completed";
  if (["in_progress","in progress","active","doing"].includes(v)) return "in_progress";
  return "open";
};
const fmtDate = (d) => d ? new Date(d).toLocaleDateString("en-US",{month:"short",day:"numeric",year:"numeric"}) : "";
const normalizeTask = (t) => ({
  ...t,
  status:          normStatus(t.status),
  task_category:   t.task_category || null,
  in_weekly_focus: !!t.in_weekly_focus,
  due_date:        fmtDate(t.due_date),
  completed_at:    fmtDate(t.completed_at),
});

// ─── Main Tasks & Goals Module ────────────────────────────────
export default function TasksGoals({ onNavigate }) {
  const [section,  setSection]  = useState("overview");
  const { data: liveTasks, loading: tasksLoading } = useSupabaseTable("tasks", AGENCY_ID, { orderBy: "due_date", ascending: true });
  const { data: liveGoals, loading: goalsLoading } = useSupabaseTable("goals", AGENCY_ID, { orderBy: "target_date", ascending: true });
  const useMockData = import.meta.env.VITE_USE_MOCK_DATA !== "false";

  const [tasks, setTasks] = useState(useMockData ? MOCK_TASKS : []);
  useEffect(() => {
    if (Array.isArray(liveTasks) && liveTasks.length > 0) {
      setTasks(liveTasks.map(normalizeTask));
    }
  }, [liveTasks]);

  const goals = (Array.isArray(liveGoals) && liveGoals.length > 0)
    ? liveGoals
    : useMockData ? MOCK_GOALS : [];

  if (tasksLoading || goalsLoading) return <div style={{padding:40,textAlign:"center",fontSize:13,color:"#64748B"}}>Loading tasks and goals…</div>;
  if (tasks.length === 0 && goals.length === 0) return <EmptyState module="tasks" />;

  // Mark complete (optimistic + persist).
  const completeTask = async (id) => {
    const prevSnapshot = tasks;
    setTasks(prev => prev.map(t => t.id === id
      ? { ...t, status:"completed", completed_at:fmtDate(new Date()) }
      : t
    ));
    if (supabase && typeof id === "string" && !id.startsWith("t")) {
      const { error } = await supabase
        .from("tasks")
        .update({ status:"closed", completed_at:new Date().toISOString() })
        .eq("id", id)
        .eq("agency_id", AGENCY_ID);
      if (error) { console.error("[TasksGoals] completeTask failed:", error); setTasks(prevSnapshot); }
    }
  };

  // Toggle in_weekly_focus (optimistic + persist).
  const toggleWeekly = async (id, next) => {
    const prevSnapshot = tasks;
    setTasks(prev => prev.map(t => t.id === id ? { ...t, in_weekly_focus: !!next } : t));
    if (supabase && typeof id === "string" && !id.startsWith("t")) {
      const { error } = await supabase
        .from("tasks")
        .update({ in_weekly_focus: !!next, updated_at: new Date().toISOString() })
        .eq("id", id)
        .eq("agency_id", AGENCY_ID);
      if (error) { console.error("[TasksGoals] toggleWeekly failed:", error); setTasks(prevSnapshot); }
    }
  };

  // Persist new task to Supabase, then mirror into local state from the returned row.
  const addTask = async (draft) => {
    if (!supabase) {
      // Offline / mock fallback — keep prior behavior so the modal still works.
      setTasks(prev => [{
        id: `t${Date.now()}`,
        title: draft.title,
        description: draft.description,
        priority: draft.priority,
        task_category: draft.task_category,
        in_weekly_focus: !!draft.in_weekly_focus,
        status: "open",
        created_by: "Peter",
        due_date: draft.due_date ? fmtDate(draft.due_date) : "",
        completed_at: "",
      }, ...prev]);
      return;
    }
    const payload = {
      agency_id:       AGENCY_ID,
      title:           draft.title,
      description:     draft.description,
      priority:        draft.priority,
      task_category:   draft.task_category,
      in_weekly_focus: !!draft.in_weekly_focus,
      due_date:        draft.due_date || null,
      status:          "open",
      created_by:      "peter",
    };
    const { data, error } = await supabase
      .from("tasks")
      .insert(payload)
      .select()
      .maybeSingle();
    if (error) {
      console.error("[TasksGoals] addTask insert failed:", error);
      return;
    }
    if (data) {
      setTasks(prev => [normalizeTask(data), ...prev]);
    }
  };

  const openInWeek = tasks.filter(t => t.in_weekly_focus && t.status !== "completed").length;

  const sections = [
    { id:"overview",  label:"Overview"  },
    { id:"week",      label:`This Week${openInWeek?` (${openInWeek})`:""}` },
    { id:"tasks",     label:"Tasks"     },
    { id:"goals",     label:"Goals"     },
    { id:"completed", label:"Completed" },
  ];

  return (
    <div>
      {/* Module Header */}
      <div style={{ display:"flex", alignItems:"flex-start", justifyContent:"space-between", marginBottom:16, flexWrap:"wrap", gap:10 }}>
        <div>
          <div style={{ fontSize:20, fontWeight:700, color:T.slate900, letterSpacing:"-0.02em" }}>Tasks & Goals</div>
          <div style={{ fontSize:12, color:T.slate500, marginTop:3 }}>
            {tasks.filter(t=>t.status!=="completed").length} open · {openInWeek} in this week · {goals.length} active goals · {tasks.filter(t=>t.status==="completed").length} completed
          </div>
        </div>
        <AskBtn context="Give me a complete review of my tasks and goals. What are the most critical items I should focus on today? What's at risk of falling behind? Help me build a clear action plan for this week." />
      </div>

      {/* Section Navigation */}
      <div style={{ display:"flex", gap:2, background:T.slate100, borderRadius:10, padding:4, marginBottom:18, overflowX:"auto", whiteSpace:"nowrap" }}>
        {sections.map(s => (
          <button key={s.id} onClick={() => setSection(s.id)} style={{ padding:"7px 14px", fontSize:12, fontWeight:section===s.id?600:400, color:section===s.id?T.slate900:T.slate500, background:section===s.id?T.white:"transparent", border:"none", borderRadius:7, cursor:"pointer", transition:"all 0.12s", boxShadow:section===s.id?"0 1px 3px rgba(0,0,0,0.08)":"none", flexShrink:0 }}>
            {s.label}
          </button>
        ))}
      </div>

      {/* Section Content */}
      {section === "overview"  && <TasksOverview tasks={tasks} goals={goals} onComplete={completeTask} onNavigate={onNavigate||(()=>{})} onToggleWeekly={toggleWeekly} onJumpToWeek={() => setSection("week")} />}
      {section === "week"      && <ThisWeekSection tasks={tasks} onComplete={completeTask} onNavigate={onNavigate||(()=>{})} onToggleWeekly={toggleWeekly} onJumpToAll={() => setSection("tasks")} />}
      {section === "tasks"     && <TasksList     tasks={tasks} onComplete={completeTask} onNavigate={onNavigate||(()=>{})} onAdd={addTask} onToggleWeekly={toggleWeekly} />}
      {section === "goals"     && <GoalsSection  goals={goals} />}
      {section === "completed" && <CompletedSection tasks={tasks} />}
    </div>
  );
}
