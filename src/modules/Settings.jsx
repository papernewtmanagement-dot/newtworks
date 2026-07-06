 import { useState, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
// eslint-disable-next-line no-unused-vars
// import { useState } from "react";

// ============================================================
// Newtworks SETTINGS MODULE v1.0
// Newtworks — State Farm Agent Edition
// Built by Imaginary Farms LLC · imaginary-farms.com
//
// SECTIONS:
//   1. Agency Profile   — Entity details, contact info, agent code
//   2. Team Access      — User management, roles, invite flow
//   3. Connected Accounts — Composio connections status
//   4. Newtworks Configuration — Timezone, fiscal year, display prefs
//   5. About            — Version info, built by, support
//
// ROLE LEVELS:
//   Owner      — Full access to everything including settings
//   Manager    — All modules except settings and financials
//   Staff      — Tasks, social, calendar, documents
//   Read Only  — View only on assigned modules
//   Accountant — Financials and documents, read only by default
//
// DATA: Reads agency, users, settings, notification_preferences,
//       social_accounts tables in Supabase
// ============================================================


// ─── Design Tokens ────────────────────────────────────────────
import { T } from "../lib/theme.js";

// ─── Role Config ──────────────────────────────────────────────
const ROLES = {
  owner:     { label:"Owner",      color:T.slate900,   bg:T.slate100, description:"Full access including settings and all financial data" },
  manager:   { label:"Manager",    color:T.blue,   bg:T.blueLt,  description:"All modules except Settings. Can manage team." },
  staff:     { label:"Staff",      color:T.green,  bg:T.greenLt, description:"Tasks, Social Media, Calendar, Documents only" },
  readonly:  { label:"Read Only",  color:T.slate500,bg:T.slate100,description:"View-only access to assigned modules" },
  accountant:{ label:"Accountant", color:T.purple, bg:T.purpleLt,description:"Financials and Documents read-only access" },
};

// ─── Shared Components ────────────────────────────────────────
const Card = ({ children, style={} }) => (
  <div style={{ background:T.white, border:`1px solid ${T.slate200}`, borderRadius:12, padding:"16px 18px", ...style }}>
    {children}
  </div>
);

const Pill = ({ children, type = "info" }) => {
  const map = {
    success: { bg: T.greenLt,  color: "#065F46" },
    warning: { bg: T.amberLt,  color: "#92400E" },
    danger:  { bg: T.redLt,    color: "#991B1B" },
    info:    { bg: T.blueLt,   color: "#1E40AF" },
    purple:  { bg: T.purple ? "#EDE9FE" : T.blueLt, color: "#5B21B6" },
  };
  const s = map[type] || map.info;
  return (
    <span style={{
      display: "inline-flex", alignItems: "center",
      fontSize: 10, fontWeight: 600,
      padding: "3px 8px", borderRadius: 20,
      background: s.bg, color: s.color,
      whiteSpace: "nowrap",
    }}>{children}</span>
  );
};


const SectionHeader = ({ title, sub }) => (
  <div style={{ marginBottom:16 }}>
    <div style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>{title}</div>
    {sub && <div style={{ fontSize:12, color:T.slate500, marginTop:3 }}>{sub}</div>}
  </div>
);

const Toggle = ({ value, onChange }) => (
  <div onClick={onChange} style={{ width:40, height:22, borderRadius:11, cursor:"pointer", background:value?T.green:T.slate300, position:"relative", transition:"background 0.2s", flexShrink:0 }}>
    <div style={{ width:18, height:18, borderRadius:"50%", background:T.white, position:"absolute", top:2, left:value?20:2, transition:"left 0.2s", boxShadow:"0 1px 3px rgba(0,0,0,0.2)" }} />
  </div>
);

const FieldRow = ({ label, value, editable=false, onChange, type="text", hint }) => {
  const [editing, setEditing] = useState(false);
  // Local editing buffer — initialized from value, reset whenever value changes
  // (fixes stale-state bug where agency data arrived after first render)
  const [val, setVal] = useState(value);
  useEffect(() => { setVal(value); }, [value]);

  return (
    <div style={{ display:"flex", alignItems:"flex-start", gap:12, padding:"11px 0", borderBottom:`1px solid ${T.slate100}` }}>
      <div style={{ width:180, flexShrink:0 }}>
        <div style={{ fontSize:12, fontWeight:500, color:T.slate700 }}>{label}</div>
        {hint && <div style={{ fontSize:10, color:T.slate400, marginTop:1 }}>{hint}</div>}
      </div>
      <div style={{ flex:1 }}>
        {editing ? (
          <div style={{ display:"flex", gap:8 }}>
            <input value={val} onChange={e => setVal(e.target.value)} type={type}
              style={{ flex:1, padding:"6px 10px", fontSize:12, color:T.slate800, border:`1px solid ${T.blue}`, borderRadius:7, outline:"none" }} />
            <button onClick={() => { onChange?.(val); setEditing(false); }}
              style={{ padding:"6px 12px", fontSize:11, fontWeight:600, color:T.white, background:T.blue, border:"none", borderRadius:7, cursor:"pointer" }}>Save</button>
            <button onClick={() => { setVal(value); setEditing(false); }}
              style={{ padding:"6px 10px", fontSize:11, color:T.slate500, background:T.slate100, border:"none", borderRadius:7, cursor:"pointer" }}>Cancel</button>
          </div>
        ) : (
          <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between" }}>
            <span style={{ fontSize:12, color:T.slate600 }}>{(editing ? val : value) || "—"}</span>
            {editable && (
              <button onClick={() => setEditing(true)}
                style={{ fontSize:10, color:T.blue, background:"none", border:`1px solid ${T.slate200}`, borderRadius:6, padding:"3px 8px", cursor:"pointer" }}>Edit</button>
            )}
          </div>
        )}
      </div>
    </div>
  );
};

// ─── Invite Modal ─────────────────────────────────────────────
// Per-user module overrides were dropped (migration 032 / 2026-06-22).
// Access is now purely role-based — owner/manager get full nav, all other
// roles see the team-tier modules defined in NewtworksApp.jsx TEAM_VISIBLE_ROLES.
const InviteModal = ({ onSave, onCancel, sending }) => {
  const [form, setForm] = useState({ email:"", name:"", role:"staff" });
  const set = (k,v) => setForm(f => ({...f,[k]:v}));
  const pickRole = (key) => set("role", key);

  const valid = form.email.trim() && form.name.trim();

  return (
    <div style={{ position:"fixed", inset:0, background:"rgba(15,23,42,0.5)", display:"flex", alignItems:"center", justifyContent:"center", zIndex:1000, padding:20 }}>
      <div style={{ background:T.white, borderRadius:16, width:"100%", maxWidth:480, maxHeight:"90vh", overflowY:"auto", boxShadow:"0 20px 60px rgba(0,0,0,0.2)" }}>
        <div style={{ padding:"16px 20px", borderBottom:`1px solid ${T.slate200}`, display:"flex", justifyContent:"space-between", alignItems:"center", position:"sticky", top:0, background:T.white }}>
          <span style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>Invite Team Member</span>
          <button onClick={onCancel} style={{ background:"none", border:"none", fontSize:18, color:T.slate400, cursor:"pointer" }}>×</button>
        </div>
        <div style={{ padding:20 }}>
          {[
            { label:"Full Name", key:"name",  placeholder:"Jane Doe"              },
            { label:"Email",     key:"email", placeholder:"jane@smithagency.com"  },
          ].map(f => (
            <div key={f.key} style={{ marginBottom:14 }}>
              <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>{f.label.toUpperCase()}</label>
              <input value={form[f.key]} onChange={e => set(f.key, e.target.value)} placeholder={f.placeholder}
                style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate800, border:`1px solid ${T.slate200}`, borderRadius:8, outline:"none", boxSizing:"border-box" }} />
            </div>
          ))}
          <div style={{ marginBottom:14 }}>
            <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>ACCESS ROLE</label>
            <div style={{ display:"flex", flexDirection:"column", gap:6 }}>
              {Object.entries(ROLES).filter(([k]) => k !== "owner").map(([key, role]) => (
                <div key={key} onClick={() => pickRole(key)}
                  style={{ display:"flex", alignItems:"flex-start", gap:10, padding:"10px 12px", borderRadius:9, cursor:"pointer", border:`2px solid ${form.role===key?role.color:T.slate200}`, background:form.role===key?role.bg:T.white }}>
                  <div style={{ width:16, height:16, borderRadius:"50%", border:`2px solid ${form.role===key?role.color:T.slate300}`, background:form.role===key?role.color:"transparent", flexShrink:0, marginTop:1 }} />
                  <div>
                    <div style={{ fontSize:12, fontWeight:600, color:form.role===key?role.color:T.slate800 }}>{role.label}</div>
                    <div style={{ fontSize:10, color:T.slate500, marginTop:1 }}>{role.description}</div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
        <div style={{ padding:"12px 20px", borderTop:`1px solid ${T.slate200}`, display:"flex", justifyContent:"flex-end", gap:8, position:"sticky", bottom:0, background:T.white }}>
          <button onClick={onCancel} disabled={sending} style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.slate600, background:T.slate100, border:"none", borderRadius:7, cursor:"pointer" }}>Cancel</button>
          <button
            onClick={() => valid && !sending && onSave(form)}
            disabled={!valid || sending}
            style={{ padding:"7px 16px", fontSize:11, fontWeight:600, color:T.white, background:(valid&&!sending)?T.blue:"#94A3B8", border:"none", borderRadius:7, cursor:(valid&&!sending)?"pointer":"default" }}
          >{sending ? "Sending…" : "Send Invite"}</button>
        </div>
      </div>
    </div>
  );
};

// ─── Section: Agency Profile ──────────────────────────────────
const AgencyProfile = ({ agency }) => (
  <Card>
    <SectionHeader title="Agency Profile" sub="Core agency information stored in your Supabase database" />
    <FieldRow label="Agency Name"       value={agency.name}                                           editable />
    <FieldRow label="Owner Name"        value={agency.owner_name}                                     editable />
    <FieldRow label="Entity Type"       value={agency.entity_type}                                    />
    <FieldRow label="EIN / Tax ID"      value={agency.tax_id}       hint="Stored encrypted"          />
    <FieldRow label="SF Agent Code"     value={agency.sf_agent_code}                                  />
    <FieldRow label="Licensed States"   value={(agency.licensing_states || []).join(", ")}                   editable />
    <FieldRow label="Primary Email"     value={agency.primary_email} hint="Personal — not @statefarm.com" editable />
    <FieldRow label="Phone"             value={agency.phone}                                          editable />
    <FieldRow label="Address"           value={agency.address}                                        editable />
    <FieldRow label="Google Account"    value={agency.google_account} hint="Ties Vercel, Supabase, Composio" />
    <FieldRow label="Newtworks URL"           value={agency.vercel_url}    hint="Your permanent Newtworks address" />
    <FieldRow label="Setup Date"        value={agency.setup_date}    />
  </Card>
);

// ─── Section: Team Access ─────────────────────────────────────
const TeamAccess = ({ users }) => {
  const [allUsers,    setAllUsers]    = useState(users);
  useEffect(() => { setAllUsers(users); }, [users]);
  const [showInvite,  setShowInvite]  = useState(false);
  const [editingRole, setEditingRole] = useState(null);
  const [sending,     setSending]     = useState(false);

  // Real invite: calls the invite-team-member edge function, which (1) sends a
  // Supabase Auth invite email with a magic link, and (2) upserts the users row
  // with role. The caller's JWT is forwarded so the function can verify the
  // caller is an owner/manager before inviting.
  const handleInvite = async (form) => {
    setSending(true);
    try {
      const { data: sess } = await supabase.auth.getSession();
      const token = sess?.session?.access_token;
      if (!token) { alert("Your session expired — please sign in again."); setSending(false); return; }

      const baseUrl = import.meta.env.VITE_SUPABASE_URL;
      const resp = await fetch(`${baseUrl}/functions/v1/invite-team-member`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${token}`,
          "apikey": import.meta.env.VITE_SUPABASE_ANON_KEY,
        },
        body: JSON.stringify({
          email:           form.email.trim(),
          full_name:       form.name.trim(),
          role:            form.role || "staff",
          redirect_to:     window.location.origin + "/welcome",
        }),
      });
      const result = await resp.json().catch(() => ({}));
      if (!resp.ok || !result.ok) {
        console.error("[Settings] invite error:", result);
        alert("Could not send invite: " + (result.detail || result.error || `HTTP ${resp.status}`));
        setSending(false);
        return;
      }

      // Optimistic add to the visible list as a pending invite.
      setAllUsers(prev => {
        const without = prev.filter(u => (u.email || "").toLowerCase() !== form.email.trim().toLowerCase());
        return [...without, {
          id:         result.auth_user_id || form.email.trim(),
          name:       form.name.trim(),
          email:      form.email.trim(),
          role:       form.role || "staff",
          last_login: "Never",
          is_active:  true,
          is_current: false,
          pending:    true,
        }];
      });
      setShowInvite(false);
      alert(`Invite email sent to ${form.email.trim()}. They'll get a link to set their password and sign in.`);
    } catch (e) {
      console.error("[Settings] invite exception:", e);
      alert("Could not send invite: " + (e?.message || "unknown error"));
    } finally {
      setSending(false);
    }
  };

  const handleRevoke = (id) => {
    setAllUsers(prev => prev.map(u => u.id===id ? {...u, is_active:false} : u));
  };

  const handleRoleChange = (id, role) => {
    setAllUsers(prev => prev.map(u => u.id===id ? {...u, role} : u));
    setEditingRole(null);
  };

  return (
    <div>
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:16 }}>
        <div>
          <div style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>Team Access</div>
          <div style={{ fontSize:12, color:T.slate500, marginTop:3 }}>Manage who has access to your Newtworks and what they can see</div>
        </div>
        <button onClick={() => setShowInvite(true)}
          style={{ display:"flex", alignItems:"center", gap:6, padding:"8px 16px", fontSize:11, fontWeight:600, color:T.white, background:T.blue, border:"none", borderRadius:8, cursor:"pointer" }}>
          + Invite User
        </button>
      </div>

      {/* Role Reference */}
      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit,minmax(140px,1fr))", gap:8, marginBottom:16 }}>
        {Object.entries(ROLES).map(([key, role]) => (
          <div key={key} style={{ background:role.bg, borderRadius:9, padding:"8px 10px" }}>
            <div style={{ fontSize:11, fontWeight:700, color:role.color, marginBottom:3 }}>{role.label}</div>
            <div style={{ fontSize:9, color:T.slate600, lineHeight:1.4 }}>{role.description}</div>
          </div>
        ))}
      </div>

      {/* User List */}
      <Card>
        {allUsers.filter(u => u.is_active).map((user, i) => {
          const role = ROLES[user.role] || ROLES.readonly;
          const isLast = i === allUsers.filter(u=>u.is_active).length - 1;
          return (
            <div key={user.id} style={{ display:"flex", alignItems:"center", gap:12, padding:"12px 0", borderBottom:isLast?"none":`1px solid ${T.slate100}` }}>
              {/* Avatar */}
              <div style={{ width:36, height:36, borderRadius:10, background:user.is_current?T.slate900:T.slate200, display:"flex", alignItems:"center", justifyContent:"center", fontSize:12, fontWeight:700, color:user.is_current?T.white:T.slate500, flexShrink:0 }}>
                {(user.name || "?").toString().split(" ").map(n=>n?.[0] || "").join("").slice(0,2) || "?"}
              </div>

              <div style={{ flex:1 }}>
                <div style={{ display:"flex", alignItems:"center", gap:8 }}>
                  <span style={{ fontSize:13, fontWeight:600, color:T.slate900 }}>{user.name}</span>
                  {user.is_current && <span style={{ fontSize:9, fontWeight:600, padding:"2px 6px", borderRadius:20, background:T.blue, color:T.white }}>You</span>}
                  {user.pending   && <span style={{ fontSize:9, fontWeight:600, padding:"2px 6px", borderRadius:20, background:T.amberLt, color:"#92400E" }}>Invite Pending</span>}
                </div>
                <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>{user.email} · Last login: {user.last_login}</div>
              </div>

              {/* Role */}
              {editingRole === user.id ? (
                <select
                  defaultValue={user.role}
                  onChange={e => handleRoleChange(user.id, e.target.value)}
                  autoFocus
                  onBlur={() => setEditingRole(null)}
                  style={{ padding:"5px 8px", fontSize:11, color:T.slate700, border:`1px solid ${T.blue}`, borderRadius:7, background:T.white, outline:"none" }}
                >
                  {Object.keys(ROLES).filter(r => r !== "owner" || user.role === "owner").map(r => (
                    <option key={r} value={r}>{ROLES[r].label}</option>
                  ))}
                </select>
              ) : (
                <span
                  onClick={() => !user.is_current && setEditingRole(user.id)}
                  style={{ fontSize:10, fontWeight:600, padding:"4px 10px", borderRadius:20, background:role.bg, color:role.color, cursor:user.is_current?"default":"pointer", whiteSpace:"nowrap" }}
                  title={user.is_current?"":"Click to change role"}
                >
                  {role.label}
                </span>
              )}

              {/* Revoke */}
              {!user.is_current && !user.pending && (
                <button onClick={() => handleRevoke(user.id)}
                  style={{ fontSize:10, color:T.red, background:T.redLt, border:"none", borderRadius:6, padding:"5px 10px", cursor:"pointer", whiteSpace:"nowrap" }}>
                  Revoke
                </button>
              )}
            </div>
          );
        })}
      </Card>

      {showInvite && <InviteModal onSave={handleInvite} onCancel={() => setShowInvite(false)} sending={sending} />}
    </div>
  );
};

// ─── Section: Connected Accounts ─────────────────────────────
const ConnectedAccounts = ({ connections }) => (
  <div>
    <SectionHeader title="Connected Accounts" sub="Composio manages all external connections. Reconnect any account that shows an error." />

    <div style={{ background:T.blueLt, border:`1px solid ${T.blue}20`, borderLeft:`4px solid ${T.blue}`, borderRadius:10, padding:"12px 16px", marginBottom:16 }}>
      <div style={{ fontSize:12, fontWeight:600, color:T.slate900, marginBottom:3 }}>How connections work</div>
      <div style={{ fontSize:11, color:T.slate600, lineHeight:1.6 }}>
        Your Newtworks automations use Composio to interact with Gmail, Google Drive, Facebook, LinkedIn, and Instagram on your behalf. Connections are authenticated via your Google account and each platform's OAuth. If a connection expires, automations that depend on it will fail until reconnected. All connections are managed in your Composio dashboard.
      </div>
    </div>

    <div style={{ display:"flex", flexDirection:"column", gap:8 }}>
      {connections.map(conn => (
        <Card key={conn.id} style={{ border:`1px solid ${conn.status==="error"?T.red:T.slate200}` }}>
          <div style={{ display:"flex", alignItems:"center", gap:14 }}>
            <div style={{ width:44, height:44, borderRadius:12, background:conn.status==="error"?T.redLt:T.slate50, border:`1px solid ${conn.status==="error"?T.red:T.slate200}`, display:"flex", alignItems:"center", justifyContent:"center", fontSize:22, flexShrink:0 }}>
              {conn.icon}
            </div>
            <div style={{ flex:1 }}>
              <div style={{ display:"flex", alignItems:"center", gap:8, marginBottom:3 }}>
                <span style={{ fontSize:13, fontWeight:700, color:T.slate900 }}>{conn.platform}</span>
                <span style={{ fontSize:10, fontWeight:600, padding:"3px 8px", borderRadius:20, ...{
                  healthy:{ background:T.greenLt, color:"#065F46" },
                  error:  { background:T.redLt,   color:"#991B1B" },
                  notset: { background:T.slate100,color:T.slate500 },
                  manual: { background:T.purpleLt,color:"#5B21B6" },
                }[conn.status] }}>{conn.status === "healthy" ? "Connected" : conn.status === "error" ? "Needs reconnect" : conn.status === "notset" ? "Not set up" : "Manual"}</span>
              </div>
              <div style={{ fontSize:11, color:T.slate600 }}>{conn.account}</div>
              <div style={{ fontSize:10, color:conn.status==="error"?T.red:T.slate400, marginTop:2 }}>{conn.note} · Last sync: {conn.last_sync}</div>
            </div>
            {conn.status === "error" && (
              <div style={{ display:"flex", flexDirection:"column", alignItems:"flex-end", gap:4, flexShrink:0 }}>
                <a href="https://app.composio.dev" target="_blank" rel="noopener noreferrer"
                   style={{ padding:"7px 14px", fontSize:11, fontWeight:600, color:T.white, background:T.red, border:"none", borderRadius:8, cursor:"pointer", textDecoration:"none" }}>
                  Reconnect in Composio
                </a>
                <span style={{ fontSize:9, color:T.slate400 }}>then trigger a re-sync</span>
              </div>
            )}
            {conn.status === "healthy" && (
              <div style={{ fontSize:11, color:T.green, fontWeight:600, flexShrink:0 }}>✓ Active</div>
            )}
            {conn.status === "notset" && (
              <div style={{ fontSize:10, color:T.slate400, fontWeight:600, flexShrink:0, maxWidth:130, textAlign:"right", lineHeight:1.4 }}>Connect when ready</div>
            )}
            {conn.status === "manual" && (
              <div style={{ fontSize:10, color:T.purple, fontWeight:600, flexShrink:0, maxWidth:120, textAlign:"right", lineHeight:1.4 }}>Manual posting required daily</div>
            )}
          </div>
        </Card>
      ))}
    </div>
  </div>
);

// ─── Section: Newtworks Configuration ──────────────────────────────
const BCCConfiguration = ({ config }) => {
  const [cfg, setCfg] = useState(config);
  useEffect(() => { setCfg(config); }, [config]);
  const set = (k,v) => setCfg(c => ({...c,[k]:v}));

  return (
    <div style={{ display:"flex", flexDirection:"column", gap:12 }}>
      {/* Daily Briefing */}
      <Card>
        <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:14 }}>
          <div>
            <div style={{ fontSize:13, fontWeight:700, color:T.slate900 }}>Daily Briefing Email</div>
            <div style={{ fontSize:11, color:T.slate500, marginTop:2 }}>Morning snapshot sent to your inbox every day</div>
          </div>
          <Toggle value={cfg.briefing_enabled} onChange={() => set("briefing_enabled", !cfg.briefing_enabled)} />
        </div>
        {cfg.briefing_enabled && (
          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(180px, 1fr))", gap:10 }}>
            {[
              { label:"Send Time",          key:"briefing_time",  value:cfg.briefing_time,  hint:"24hr format, agency timezone" },
              { label:"Delivery Email",     key:"briefing_email", value:cfg.briefing_email, hint:"Where briefings are sent"      },
            ].map(f => (
              <div key={f.key}>
                <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>{f.label.toUpperCase()}</label>
                <input value={f.value} onChange={e => set(f.key, e.target.value)}
                  style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate800, border:`1px solid ${T.slate200}`, borderRadius:8, outline:"none", boxSizing:"border-box" }} />
                <div style={{ fontSize:10, color:T.slate400, marginTop:3 }}>{f.hint}</div>
              </div>
            ))}
          </div>
        )}
      </Card>

      {/* Financial Settings */}
      <Card>
        <div style={{ fontSize:13, fontWeight:700, color:T.slate900, marginBottom:14 }}>Financial Settings</div>
        <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(180px, 1fr))", gap:10 }}>
          {[
            { label:"Accounting Method",   key:"accounting_method", value:cfg.accounting_method, hint:"Cash basis — do not change",  editable:false },
            { label:"Fiscal Year Start",   key:"fiscal_year_start", value:cfg.fiscal_year_start, hint:"Calendar year Jan-Dec",       editable:false },
            { label:"Currency",            key:"currency",          value:cfg.currency,          hint:"USD",                         editable:false },
            { label:"Timezone",            key:"timezone",          value:cfg.timezone,          hint:"Used for scheduling",          editable:true  },
          ].map(f => (
            <div key={f.label}>
              <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>{f.label.toUpperCase()}</label>
              {f.editable ? (
                <input value={f.value || ""} onChange={e => set(f.key, e.target.value)}
                  style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate800, border:`1px solid ${T.slate200}`, borderRadius:8, outline:"none", boxSizing:"border-box" }} />
              ) : (
                <div style={{ padding:"8px 10px", fontSize:12, color:T.slate600, background:T.slate50, borderRadius:8, border:`1px solid ${T.slate200}` }}>{f.value}</div>
              )}
              <div style={{ fontSize:10, color:T.slate400, marginTop:3 }}>{f.hint}</div>
            </div>
          ))}
        </div>
      </Card>

      {/* AIPP Settings */}
      <Card>
        <div style={{ fontSize:13, fontWeight:700, color:T.slate900, marginBottom:14 }}>AIPP Configuration</div>
        <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(180px, 1fr))", gap:10 }}>
          <div>
            <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>PROGRAM YEAR</label>
            <input defaultValue={cfg.aipp_year} type="number"
              style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate800, border:`1px solid ${T.slate200}`, borderRadius:8, outline:"none", boxSizing:"border-box" }} />
          </div>
          <div>
            <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:5 }}>AIPP TARGET ($)</label>
            <input defaultValue={cfg.aipp_target} type="number"
              style={{ width:"100%", padding:"8px 10px", fontSize:12, color:T.slate800, border:`1px solid ${T.slate200}`, borderRadius:8, outline:"none", boxSizing:"border-box" }} />
            <div style={{ fontSize:10, color:T.slate400, marginTop:3 }}>Used for progress calculations across the Newtworks</div>
          </div>
        </div>
      </Card>

      {/* Dashboard Display */}
      <Card>
        <div style={{ fontSize:13, fontWeight:700, color:T.slate900, marginBottom:14 }}>Dashboard Display</div>
        <div>
          <label style={{ fontSize:11, fontWeight:600, color:T.slate600, display:"block", marginBottom:8 }}>DEFAULT REVENUE PERIOD</label>
          <div style={{ display:"flex", gap:6 }}>
            {[{id:"mtd",label:"Month to Date"},{id:"qtd",label:"Quarter to Date"},{id:"ytd",label:"Year to Date"}].map(opt => (
              <button key={opt.id} onClick={() => set("dashboard_period", opt.id)}
                style={{ padding:"7px 14px", fontSize:11, fontWeight:cfg.dashboard_period===opt.id?600:400, color:cfg.dashboard_period===opt.id?T.white:T.slate600, background:cfg.dashboard_period===opt.id?T.slate900:T.white, border:`1px solid ${cfg.dashboard_period===opt.id?T.slate900:T.slate200}`, borderRadius:7, cursor:"pointer" }}>
                {opt.label}
              </button>
            ))}
          </div>
        </div>
      </Card>
    </div>
  );
};

// ─── Section: About ───────────────────────────────────────────
const About = ({ agency: agencyProp }) => {
  const agency = agencyProp || {};
  const [tab, setTab] = useState("stack");

  const components = [
    {
      key: "supabase", name: "Supabase", role: "Database & Memory",
      accent: "#3ECF8E", letter: "S",
      description: "Every number, document, staff record, automation log, and memory lives here. This is the brain of the Newtworks — all modules read and write from Supabase.",
      login: agency.google_account_email || agency.primary_email || "your Google account",
      url: "https://supabase.com/dashboard",
    },
    {
      key: "composio", name: "Composio", role: "Automation Engine",
      accent: "#8B5CF6", letter: "C",
      description: "Runs all your automation recipes on schedule — comp recap intake, bank statements, payroll filing, daily briefing email, inbox cleanup, monthly close.",
      login: agency.google_account_email || agency.primary_email || "your Google account",
      url: "https://app.composio.dev/",
    },
    {
      key: "drive", name: "Google Drive", role: "Document Archive",
      accent: "#FBBC04", letter: "D",
      description: "Final resting place for every source document — comp recaps, deduction statements, bank statements, payroll reports, credit card statements. Automations file here automatically after processing.",
      login: agency.google_account_email || agency.primary_email || "your Google account",
      url: "https://drive.google.com",
    },
    {
      key: "gmail", name: "Gmail", role: "Document Intake",
      accent: "#EA4335", letter: "G",
      description: "Front door for incoming documents. Composio watches this inbox, reads what arrives, sends it to Supabase, and files the original to Drive. Daily briefing also sends from here.",
      login: agency.google_account_email || agency.primary_email || "your Google account",
      url: "https://mail.google.com",
    },
    {
      key: "github", name: "GitHub", role: "Code Repository",
      accent: "#181717", letter: "G",
      description: "Your Newtworks's source code lives here. Every change to the app is committed here first, then auto-deployed to Vercel.",
      login: agency.google_account_email || agency.primary_email || "your Google account",
      url: "https://github.com",
    },
    {
      key: "vercel", name: "Vercel", role: "Hosting",
      accent: "#000000", letter: "V",
      description: "Hosts the web app you are looking at right now. Watches GitHub for changes, builds the site, and serves it at your custom URL.",
      login: agency.google_account_email || agency.primary_email || "your Google account",
      url: agency.vercel_url || "https://vercel.com/dashboard",
    },
  ];

  const tabs = [
    { id:"stack",     label:"⚡  Tech Stack" },
    { id:"how",       label:"🔄 How It Works" },
  ];

  return (
    <div style={{ display:"flex", flexDirection:"column", gap:14 }}>

      {/* Header card */}
      <Card style={{ background:T.slate900, border:"none", color:T.white }}>
        <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", flexWrap:"wrap", gap:14 }}>
          <div style={{ display:"flex", alignItems:"center", gap:14 }}>
            <div style={{ width:60, height:60, borderRadius:14, background:"rgba(255,255,255,0.08)", display:"flex", alignItems:"center", justifyContent:"center", fontSize:18, fontWeight:800, color:T.white, letterSpacing:"-0.02em" }}>
              Newtworks
            </div>
            <div>
              <div style={{ fontSize:17, fontWeight:700, color:T.white }}>Newtworks</div>
              <div style={{ fontSize:12, color:"rgba(255,255,255,0.7)", marginTop:3 }}>State Farm Agent Edition · v1.0 · Built by Imaginary Farms LLC</div>
              <div style={{ fontSize:11, color:"rgba(255,255,255,0.5)", marginTop:2 }}>imaginary-farms.com</div>
            </div>
          </div>
          <div style={{ textAlign:"right" }}>
            <div style={{ fontSize:10, color:"rgba(255,255,255,0.5)", marginBottom:4, textTransform:"uppercase", letterSpacing:"0.05em" }}>Single Google login for everything</div>
            <div style={{ fontSize:12, fontWeight:600, color:T.white, background:"rgba(255,255,255,0.1)", padding:"7px 12px", borderRadius:8 }}>
              {agency.google_account_email || agency.primary_email || "set in Agency Profile"}
            </div>
          </div>
        </div>
      </Card>

      {/* Sub-tabs */}
      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(140px, 1fr))", gap:8 }}>
        {tabs.map(t => (
          <button key={t.id} onClick={() => setTab(t.id)} style={{
            padding:"12px 14px",
            fontSize:13, fontWeight:600,
            color: tab===t.id ? T.slate900 : T.slate500,
            background: tab===t.id ? T.white : T.slate50,
            border:`1px solid ${tab===t.id ? T.slate300 : T.slate200}`,
            borderRadius:10, cursor:"pointer",
            transition:"all 0.12s",
            boxShadow: tab===t.id ? "0 1px 3px rgba(0,0,0,0.08)" : "none",
          }}>{t.label}</button>
        ))}
      </div>

      {tab === "stack" && (
        <>
          <div style={{ fontSize:12, color:T.slate600, padding:"4px 4px 0" }}>
            All {components.length} components run under one Google account — <strong style={{ color:T.slate900 }}>{agency.google_account_email || agency.primary_email || "set in Agency Profile"}</strong>
          </div>

          <div style={{ display:"flex", flexDirection:"column", gap:10 }}>
            {components.map(c => (
              <Card key={c.key} style={{ borderLeft:`4px solid ${c.accent}`, padding:"14px 16px" }}>
                <div style={{ display:"flex", alignItems:"flex-start", gap:14 }}>
                  <div style={{
                    width:38, height:38, borderRadius:10,
                    background:`${c.accent}15`,
                    color:c.accent,
                    display:"flex", alignItems:"center", justifyContent:"center",
                    fontSize:18, fontWeight:800, flexShrink:0,
                  }}>{c.letter}</div>
                  <div style={{ flex:1, minWidth:0 }}>
                    <div style={{ display:"flex", alignItems:"center", gap:10, marginBottom:4, flexWrap:"wrap" }}>
                      <span style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>{c.name}</span>
                      <Pill type="info">{c.role}</Pill>
                    </div>
                    <div style={{ fontSize:12, color:T.slate600, lineHeight:1.55, marginBottom:8 }}>{c.description}</div>
                    <div style={{ fontSize:11, color:T.slate500 }}>
                      <span style={{ fontWeight:600, color:T.slate700 }}>Login:</span> {c.login} <span style={{ color:T.slate400 }}>(Google)</span>
                    </div>
                  </div>
                  <a href={c.url} target="_blank" rel="noopener noreferrer" style={{
                    fontSize:12, fontWeight:600, color:T.blue, textDecoration:"none",
                    padding:"6px 12px", borderRadius:7, border:`1px solid ${T.slate200}`,
                    flexShrink:0, whiteSpace:"nowrap",
                  }}>Open </a>
                </div>
              </Card>
            ))}
          </div>
        </>
      )}

      {tab === "how" && (
        <Card>
          <div style={{ fontSize:14, fontWeight:700, color:T.slate900, marginBottom:14 }}>How the Newtworks works</div>
          <div style={{ display:"flex", flexDirection:"column", gap:14 }}>
            {[
              { step:"1", title:"Documents arrive in Gmail",
                detail:"Your bank, Gusto, State Farm, and credit card emails land in your Gmail inbox automatically." },
              { step:"2", title:"Composio reads the inbox on schedule",
                detail:"Hourly automation recipes scan for new statements, payroll runs, and SF comp recaps." },
              { step:"3", title:"Groq processes documents (free, no API key)",
                detail:"Composio passes each document to Groq for structured extraction — line items, dates, amounts." },
              { step:"4", title:"Data lands in Supabase",
                detail:"Extracted rows write to the right tables — journal_entries, comp_recap, payroll_detail, etc." },
              { step:"5", title:"Original document files to Drive",
                detail:"After processing, the original PDF/CSV moves to your Google Drive in the right folder." },
              { step:"6", title:"This Newtworks web app reads from Supabase",
                detail:"Every module you see — Financials, Compliance, HR, Tasks — pulls live from Supabase." },
            ].map(s => (
              <div key={s.step} style={{ display:"flex", gap:14, alignItems:"flex-start" }}>
                <div style={{ width:30, height:30, borderRadius:8, background:T.blueLt, color:T.blue, display:"flex", alignItems:"center", justifyContent:"center", fontSize:13, fontWeight:700, flexShrink:0 }}>{s.step}</div>
                <div>
                  <div style={{ fontSize:13, fontWeight:600, color:T.slate900, marginBottom:2 }}>{s.title}</div>
                  <div style={{ fontSize:12, color:T.slate600, lineHeight:1.55 }}>{s.detail}</div>
                </div>
              </div>
            ))}
          </div>
        </Card>
      )}


      {/* Footer */}
      <Card style={{ textAlign:"center", padding:"18px 20px", background:T.slate50, border:"none" }}>
        <div style={{ fontSize:13, fontWeight:700, color:T.slate900, marginBottom:4 }}>Built by Imaginary Farms LLC</div>
        <a href="https://imaginary-farms.com" target="_blank" rel="noopener noreferrer"
          style={{ fontSize:12, color:T.blue, textDecoration:"none", fontWeight:500 }}>
          imaginary-farms.com
        </a>
        <div style={{ marginTop:10, fontSize:11, color:T.slate500, lineHeight:1.5 }}>
          You own everything. Your Newtworks is not a subscription. Your Vercel hosts the app · your GitHub holds the code · your Supabase stores your data · your Composio connects your accounts.
        </div>
      </Card>
    </div>
  );
};

// ─── Main Settings Module ─────────────────────────────────────
export default function Settings() {

  const [agencyData, setAgencyData] = useState(null);
  const [settingsData, setSettingsData] = useState([]);
  const [usersData, setUsersData] = useState([]);
  const [runLogData, setRunLogData] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function loadSettings() {
      if (!supabase || !AGENCY_ID) { setLoading(false); return; }
      try {
        const [agencyRes, settingsRes, usersRes, runLogRes] = await Promise.all([
          supabase.from("agency").select("*").eq("id", AGENCY_ID).maybeSingle(),
          supabase.from("settings").select("*").eq("agency_id", AGENCY_ID),
          supabase.from("users").select("*").eq("agency_id", AGENCY_ID),
          supabase.from("automation_run_log").select("status, run_at").eq("agency_id", AGENCY_ID).order("run_at", { ascending: false }).limit(50),
        ]);
        if (agencyRes.data) setAgencyData(agencyRes.data);
        else if (agencyRes.error) console.error("[Settings] agency fetch error:", agencyRes.error);
        if (settingsRes.data) setSettingsData(settingsRes.data);
        if (usersRes.data) setUsersData(usersRes.data);
        if (runLogRes.data) setRunLogData(runLogRes.data);
      } catch(e) { console.error("Settings load error:", e); }
      finally { setLoading(false); }
    }
    loadSettings();
  }, []);

  const [section, setSection] = useState("profile");

  const sections = [
    { id:"profile",     label:"Agency Profile"    },
    { id:"team",        label:"Team Access"        },
    { id:"connections", label:"Connections"        },
    { id:"config",      label:"Configuration"      },
    { id:"about",       label:"About"              },
  ];

  // ─── Derived live data (replaces the MOCK_* constants) ─────────
  const settingsMap = Object.fromEntries(
    (settingsData || []).map(r => [r.setting_key, r.setting_value])
  );

  const liveAgency = agencyData ? {
    name:             agencyData.name,
    owner_name:       agencyData.owner_name,
    entity_type:      agencyData.entity_type,
    tax_id:           agencyData.tax_id,
    sf_agent_code:    agencyData.state_farm_agent_code,
    state_farm_agent_code: agencyData.state_farm_agent_code,
    licensing_states: agencyData.licensing_states || [],
    primary_email:    agencyData.primary_email,
    phone:            agencyData.phone,
    address:          agencyData.address,
    google_account:   agencyData.google_account_email,
    google_account_email: agencyData.google_account_email,
    vercel_url:       agencyData.vercel_url,
    setup_date:       agencyData.setup_date,
  } : {
    name: "—", owner_name: "—", entity_type: "—", tax_id: "—",
    sf_agent_code: "—", state_farm_agent_code: "—",
    licensing_states: [], primary_email: "—",
    phone: "—", address: "—",
    google_account: "—", google_account_email: "—",
    vercel_url: "—", setup_date: "—",
  };

  const liveUsers = (usersData || []).map(u => ({
    id:         u.id,
    name:       u.full_name || u.email || "Unnamed user",
    email:      u.email,
    role:       u.role || "staff",
    last_login: u.last_login
                  ? new Date(u.last_login).toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" })
                  : "Never",
    is_active:  u.is_active !== false,
    pending:    u.invite_status === "invited" || u.invite_status === "pending" || !u.auth_user_id,
    is_current: false,
  }));

  // ── Connections: live status ────────────────────────────────────────────
  // An OAuth connection is "connected" when its composio_<x>_account_id is
  // present in settings. The Composio/Groq engine is "healthy" when something
  // has succeeded in the run log within the last 24h (a signal anon can read).
  const _engineHealthy = (runLogData || []).some(r =>
    r.status === "success" && r.run_at &&
    (Date.now() - new Date(r.run_at).getTime()) < 24 * 3600000
  );
  const _lastSuccess = (runLogData || []).find(r => r.status === "success")?.run_at || null;
  const _syncLabel = _lastSuccess
    ? new Date(_lastSuccess).toLocaleString("en-US", { dateStyle:"medium", timeStyle:"short" })
    : "—";

  const connSpecs = [
    { key:"composio_gmail_account_id",          icon:"📧", platform:"Gmail",           account:liveAgency.google_account || "Google Workspace", note:"Email intake + archiver" },
    { key:"composio_googledrive_account_id",    icon:"📁", platform:"Google Drive",    account:liveAgency.google_account || "Google Workspace", note:"Where documents are filed" },
    { key:"composio_googlecalendar_account_id", icon:"📅", platform:"Google Calendar", account:liveAgency.google_account || "Google Workspace", note:"Scheduling + reminders" },
    { key:"composio_github_account_id",         icon:"🐙", platform:"GitHub",          account:"papernewtmanagement-dot",   note:"Newtworks app code repository" },
    { key:"composio_supabase_account_id",       icon:"🗄️", platform:"Supabase",        account:liveAgency.name || "Newtworks database", note:"The agency database" },
    { key:"composio_facebook_account_id",       icon:"📘", platform:"Facebook Pages",  account:"Facebook Business",         note:"Auto-posts approved content", setupLater:true },
    { key:"composio_linkedin_account_id",       icon:"💼", platform:"LinkedIn",        account:"LinkedIn Profile",          note:"Auto-posts approved content", setupLater:true },
    { key:"composio_instagram_account_id",      icon:"📷", platform:"Instagram",       account:"Instagram (manual)",        note:"API allows reminders only", manual:true },
  ];
  const liveConns = connSpecs.map((s, i) => {
    const present = Boolean(settingsMap[s.key]);
    let status;
    if (s.manual) status = "manual";
    else if (present) status = "healthy";
    else status = s.setupLater ? "notset" : "error";
    return {
      id:        `c${i+1}`,
      platform:  s.platform,
      icon:      s.icon,
      status,
      account:   present ? s.account : (s.setupLater ? "Not connected yet (optional)" : "Not connected"),
      last_sync: (present && !s.manual) ? _syncLabel : "—",
      note:      s.note,
    };
  });
  // Always-on engine row (Composio action layer + Groq parsing)
  liveConns.push({
    id:"engine", platform:"Composio + Groq Engine", icon:"⚙️",
    status: _engineHealthy ? "healthy" : (settingsMap["composio_api_key"] ? "error" : "error"),
    account: settingsMap["composio_api_key"] ? "API key present" : "API key missing",
    last_sync: _engineHealthy ? _syncLabel : "—",
    note: _engineHealthy ? "Action layer + LLM parsing active" : "No successful runs in last 24h — investigate run log",
  });

  const liveConfig = {
    timezone:           settingsMap.timezone           || "America/Chicago",
    fiscal_year_start:  settingsMap.fiscal_year_start  || "January 1",
    accounting_method:  settingsMap.accounting_method  || "Cash Basis",
    currency:           settingsMap.currency           || "USD",
    briefing_time:      settingsMap.briefing_time      || "7:00 AM",
    briefing_email:     settingsMap.briefing_email     || liveAgency.primary_email,
    briefing_enabled:   settingsMap.briefing_enabled === "true",
    aipp_target:        Number(settingsMap.aipp_target || 0),
    aipp_year:          Number(settingsMap.aipp_year || new Date().getFullYear()),
    dashboard_period:   settingsMap.dashboard_period   || "mtd",
  };

  return (
    <div>
      {/* Module Header */}
      <div style={{ marginBottom:16 }}>
        <div style={{ fontSize:20, fontWeight:700, color:T.slate900, letterSpacing:"-0.02em" }}>Settings</div>
        <div style={{ fontSize:12, color:T.slate500, marginTop:3 }}>
          Agency profile · Team access · Connected accounts · Newtworks configuration
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
      {section === "profile"     && <AgencyProfile      agency={liveAgency}     />}
      {section === "team"        && <TeamAccess         users={liveUsers}       />}
      {section === "connections" && <ConnectedAccounts  connections={liveConns} />}
      {section === "config"      && <BCCConfiguration   config={liveConfig}     />}
      {section === "about"       && <About              agency={liveAgency}     />}
    </div>
  );
}
