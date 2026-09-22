// =========================================================================
// OnboardingTemplateEditor.jsx
// =========================================================================
// The Template subtab of Onboarding. Reads the master step list and lets an
// owner or manager change it without going through the database.
//
// One surface, not two. The page still reads like the old read-only view —
// phases down the page, one card per step, two columns where a phase has
// two tracks. Editing is layered on top of that: click a step to open it,
// use the small arrows to move it, use the dashed row at the bottom of a
// phase to add one.
//
// Table: onboarding_step_templates. Changes flow into every running plan
// through onboarding_sync_plan(); ticked boxes stay ticked.
// =========================================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { TabLink, useTabParam } from "../lib/routing.jsx";
import { useViewport } from "../lib/hooks.js";
import {
  Card, Pill, Button, fieldLabel, inputBase, trackHeadStyle,
  CATEGORY_COLORS, CATEGORY_KEYS, STAGE_LABELS,
  subGroups, substepsToText, textToSubsteps, trackColumns, wrapLongText, LabelText,
} from "../lib/onboardingUi.jsx";
import { FORMS } from "./TeamForms.jsx";

const COLS = "id, template_key, title, description, phase, category, applies_to_roles, applies_to_role_categories, applies_to_role_levels, is_required, sort_order, notes, substeps, owner_kind, assigned_to, track, track_order, blocked_by, is_active, unlock_rule, widget";

const NEW_ID = "new";

// ─── small helpers ──────────────────────────────────
function slugify(s) {
  return String(s || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 60) || "step";
}

function appliesToText(t) {
  const bits = [];
  if (t.applies_to_roles?.length) bits.push(t.applies_to_roles.join(", "));
  if (t.applies_to_role_categories?.length) bits.push(t.applies_to_role_categories.join(", "));
  if (t.applies_to_role_levels?.length) bits.push(t.applies_to_role_levels.join(", "));
  return bits.length ? bits.join(" · ") : "Everyone";
}

function personName(t) {
  if (!t) return "";
  const first = (t.nickname && t.nickname.trim()) || t.first_name || "";
  const last = t.last_name || "";
  return `${first} ${last}`.trim() || "Teammate";
}

// "Who does it" is one control, so the three database fields are packed
// into one value and unpacked on save.
function ownerValue(row) {
  if (row.owner_kind === "admin" && row.assigned_to) return `person:${row.assigned_to}`;
  return row.owner_kind || "new_hire";
}
function ownerPatch(value) {
  if (String(value || "").startsWith("person:")) {
    return { owner_kind: "admin", assigned_to: String(value).slice(7) };
  }
  return { owner_kind: value || "new_hire", assigned_to: null };
}

const nz = (arr) => (Array.isArray(arr) && arr.length ? arr : null);

// ─── chip multi-select ──────────────────────────────
function Chips({ options, selected, onToggle }) {
  if (!options.length) return null;
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
      {options.map(opt => {
        const on = selected.includes(opt);
        return (
          <button
            key={opt}
            onClick={() => onToggle(opt)}
            style={{
              padding: "5px 10px", fontSize: 12, fontWeight: 600, borderRadius: 999,
              boxSizing: "border-box", cursor: "pointer",
              color: on ? T.white : T.slate700,
              background: on ? T.blue : T.white,
              border: `1px solid ${on ? T.blue : T.slate300}`,
            }}
          >{opt}</button>
        );
      })}
    </div>
  );
}

// ─── the step editor ────────────────────────────────
function StepEditor({ row, isNew, rows, phaseOptions, people, onClose, onSaved }) {
  const vp = useViewport();
  const [form, setForm] = useState(() => ({
    template_key: row.template_key || "",
    title: row.title || "",
    description: row.description || "",
    subText: substepsToText(row.substeps),
    phase: row.phase,
    category: row.category || "training",
    owner: ownerValue(row),
    is_required: row.is_required !== false,
    track: row.track || "",
    track_order: row.track_order || 0,
    sort_order: row.sort_order || 100,
    blocked_by: Array.isArray(row.blocked_by) ? row.blocked_by : [],
    unlock_rule: row.unlock_rule || "",
    applies_to_roles: Array.isArray(row.applies_to_roles) ? row.applies_to_roles : [],
    applies_to_role_categories: Array.isArray(row.applies_to_role_categories) ? row.applies_to_role_categories : [],
    applies_to_role_levels: Array.isArray(row.applies_to_role_levels) ? row.applies_to_role_levels : [],
    notes: row.notes || "",
  }));
  const [keyTouched, setKeyTouched] = useState(!isNew);
  const [more, setMore] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");

  // Pop-up instructions for the step itself live in onboarding_instructions,
  // matched to the step by its title, the same way sub-items match theirs.
  const [instr, setInstr] = useState({ id: null, text: "" });
  const [instrOpen, setInstrOpen] = useState(false);
  useEffect(() => {
    if (isNew || !row.title) return undefined;
    let cancelled = false;
    supabase.from("onboarding_instructions")
      .select("id, body_md")
      .eq("agency_id", AGENCY_ID)
      .eq("substep_label", row.title)
      .maybeSingle()
      .then(({ data }) => { if (!cancelled && data) setInstr({ id: data.id, text: data.body_md || "" }); });
    return () => { cancelled = true; };
  }, [isNew, row.title]);

  const set = (patch) => setForm(f => ({ ...f, ...patch }));

  // A new step names itself from its title until the key is edited by hand.
  const effectiveKey = keyTouched ? form.template_key : slugify(form.title);

  const targetOptions = useMemo(() => {
    const grab = (field, extra) => {
      const s = new Set();
      rows.forEach(r => (r[field] || []).forEach(v => s.add(v)));
      (extra || []).forEach(v => { if (v) s.add(v); });
      return [...s].sort();
    };
    return {
      roles: grab("applies_to_roles", people.map(p => p.role)),
      cats: grab("applies_to_role_categories", people.map(p => p.role_category)),
      levels: grab("applies_to_role_levels", people.map(p => p.role_level)),
    };
  }, [rows, people]);

  const trackOptions = useMemo(() => {
    const s = new Set();
    rows.forEach(r => { if (r.track) s.add(r.track); });
    return [...s].sort();
  }, [rows]);

  // Only steps that could plausibly come first are offered as blockers.
  const blockerOptions = useMemo(() => {
    const pool = rows.filter(r => r.id !== row.id && r.phase <= form.phase && r.template_key);
    const extra = form.blocked_by
      .filter(k => !pool.some(r => r.template_key === k))
      .map(k => ({ id: `ghost_${k}`, template_key: k, title: k, phase: 0 }));
    return [...pool, ...extra].sort((a, b) => (a.phase - b.phase) || a.title.localeCompare(b.title));
  }, [rows, row.id, form.phase, form.blocked_by]);

  const toggle = (field, value) => setForm(f => ({
    ...f,
    [field]: f[field].includes(value) ? f[field].filter(v => v !== value) : [...f[field], value],
  }));

  const save = async () => {
    setErr("");
    const title = form.title.trim();
    if (!title) { setErr("Give the step a title."); return; }
    const key = (effectiveKey || "").trim();
    if (!key) { setErr("Give the step a key."); return; }
    if (rows.some(r => r.id !== row.id && r.template_key === key)) {
      setErr(`Another step already uses the key "${key}".`); return;
    }

    const patch = {
      template_key: key,
      title,
      description: form.description.trim() || null,
      substeps: textToSubsteps(form.subText),
      phase: Number(form.phase),
      category: form.category,
      is_required: !!form.is_required,
      track: form.track.trim() || null,
      track_order: Number(form.track_order) || 0,
      sort_order: Number(form.sort_order) || 100,
      blocked_by: nz(form.blocked_by),
      unlock_rule: form.unlock_rule || null,
      applies_to_roles: nz(form.applies_to_roles),
      applies_to_role_categories: nz(form.applies_to_role_categories),
      applies_to_role_levels: nz(form.applies_to_role_levels),
      notes: form.notes.trim() || null,
      updated_at: new Date().toISOString(),
      ...ownerPatch(form.owner),
    };

    setBusy(true);
    try {
      if (isNew) {
        const { error } = await supabase
          .from("onboarding_step_templates")
          .insert({ ...patch, agency_id: AGENCY_ID, is_active: true });
        if (error) throw error;
      } else {
        const { error } = await supabase
          .from("onboarding_step_templates")
          .update(patch)
          .eq("id", row.id);
        if (error) throw error;

        // Renaming a key would orphan every step waiting on it, so carry
        // the new name into their "waits on" lists in the same breath.
        const oldKey = row.template_key;
        if (oldKey && oldKey !== key) {
          const dependents = rows.filter(r => r.id !== row.id && (r.blocked_by || []).includes(oldKey));
          for (const d of dependents) {
            const next = (d.blocked_by || []).map(k => (k === oldKey ? key : k));
            await supabase.from("onboarding_step_templates")
              .update({ blocked_by: next, updated_at: new Date().toISOString() })
              .eq("id", d.id);
          }
        }
      }
      // The step's pop-up instructions follow its title.
      const body = instr.text.trim();
      if (instr.id && !body) {
        const { error: ie } = await supabase.from("onboarding_instructions").delete().eq("id", instr.id);
        if (ie) throw ie;
      } else if (instr.id) {
        const { error: ie } = await supabase.from("onboarding_instructions")
          .update({ substep_label: title, body_md: body, updated_at: new Date().toISOString() })
          .eq("id", instr.id);
        if (ie) throw ie;
      } else if (body) {
        const { error: ie } = await supabase.from("onboarding_instructions")
          .insert({ agency_id: AGENCY_ID, substep_label: title, title, body_md: body });
        if (ie) throw ie;
      }
      await onSaved();
      onClose();
    } catch (e) {
      setErr(e.message || "Could not save the step.");
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!confirm(`Delete "${row.title}" from the template? This cannot be undone. Plans already running keep their copy.`)) return;
    setBusy(true); setErr("");
    try {
      const dependents = rows.filter(r => r.id !== row.id && (r.blocked_by || []).includes(row.template_key));
      for (const d of dependents) {
        const next = (d.blocked_by || []).filter(k => k !== row.template_key);
        await supabase.from("onboarding_step_templates")
          .update({ blocked_by: next.length ? next : null, updated_at: new Date().toISOString() })
          .eq("id", d.id);
      }
      const { error } = await supabase.from("onboarding_step_templates").delete().eq("id", row.id);
      if (error) throw error;
      await onSaved();
      onClose();
    } catch (e) {
      setErr(e.message || "Could not delete the step.");
      setBusy(false);
    }
  };

  const twoUp = {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))",
    gap: 12,
  };

  return (
    <div
      onClick={onClose}
      style={{
        position: "fixed", inset: 0, background: "rgba(15,23,42,0.45)",
        display: "flex", alignItems: "flex-start", justifyContent: "center",
        padding: vp.isPhone ? 10 : 28, overflowY: "auto", zIndex: 1000,
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: T.white, borderRadius: 14, border: `1px solid ${T.slate200}`,
          width: "100%", maxWidth: 640, boxSizing: "border-box",
          padding: vp.isPhone ? "16px 14px" : "20px 22px",
        }}
      >
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 14 }}>
          {isNew ? "New step" : "Edit step"}
        </div>

        <div style={{ display: "grid", gap: 12 }}>
          <div>
            <label style={fieldLabel}>Step</label>
            <input
              style={inputBase}
              value={form.title}
              autoFocus
              placeholder="What has to happen"
              onChange={(e) => set({ title: e.target.value })}
            />
          </div>

          <div>
            <label style={fieldLabel}>Detail</label>
            <textarea
              style={{ ...inputBase, minHeight: 52, resize: "vertical", fontFamily: "inherit" }}
              value={form.description}
              placeholder="One line of context. Optional."
              onChange={(e) => set({ description: e.target.value })}
            />
          </div>

          <div>
            <label style={fieldLabel}>Sub-items</label>
            <textarea
              style={{ ...inputBase, minHeight: 96, resize: "vertical", fontFamily: "inherit", lineHeight: 1.5 }}
              value={form.subText}
              placeholder={"One per line.\nEnd a line with : to start a group."}
              onChange={(e) => set({ subText: e.target.value })}
            />
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 4 }}>
              One per line. A line ending in a colon becomes a heading for the lines under it.
            </div>
          </div>

          {(instr.text || instrOpen) ? (
            <div>
              <label style={fieldLabel}>Pop-up instructions</label>
              <textarea
                style={{ ...inputBase, minHeight: 120, resize: "vertical", fontFamily: "inherit", lineHeight: 1.5 }}
                value={instr.text}
                placeholder="Opens from the ⓘ next to the step."
                onChange={(e) => setInstr(v => ({ ...v, text: e.target.value }))}
              />
            </div>
          ) : (
            <button
              type="button"
              onClick={() => setInstrOpen(true)}
              style={{ alignSelf: "flex-start", justifySelf: "start", background: "none", border: "none", padding: 0, color: T.blue, fontSize: 12, fontWeight: 600, cursor: "pointer" }}
            >Add pop-up instructions</button>
          )}

          <div style={twoUp}>
            <div>
              <label style={fieldLabel}>Phase</label>
              <select style={inputBase} value={form.phase} onChange={(e) => set({ phase: Number(e.target.value) })}>
                {phaseOptions.map(p => (
                  <option key={p.phase} value={p.phase}>{p.name}{p.is_active === false ? " (hidden)" : ""}</option>
                ))}
              </select>
            </div>
            <div>
              <label style={fieldLabel}>Category</label>
              <select style={inputBase} value={form.category} onChange={(e) => set({ category: e.target.value })}>
                {CATEGORY_KEYS.map(c => (
                  <option key={c} value={c}>{CATEGORY_COLORS[c]?.label || c}</option>
                ))}
              </select>
            </div>
          </div>

          <div style={twoUp}>
            <div>
              <label style={fieldLabel}>Who does it</label>
              <select style={inputBase} value={form.owner} onChange={(e) => set({ owner: e.target.value })}>
                <option value="new_hire">New hire</option>
                <option value="team">Everyone on the team</option>
                <option value="admin">Admin (anyone)</option>
                {people.map(p => (
                  <option key={p.id} value={`person:${p.id}`}>{personName(p)}</option>
                ))}
              </select>
            </div>
            <div>
              <label style={fieldLabel}>Required</label>
              <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: T.slate700, paddingTop: 8 }}>
                <input
                  type="checkbox"
                  checked={!!form.is_required}
                  onChange={(e) => set({ is_required: e.target.checked })}
                  style={{ width: 16, height: 16 }}
                />
                Must be done
              </label>
            </div>
          </div>

          <button
            onClick={() => setMore(m => !m)}
            style={{
              background: "transparent", border: "none", padding: 0, cursor: "pointer",
              fontSize: 12, fontWeight: 600, color: T.blue, textAlign: "left",
            }}
          >{more ? "Hide extra settings" : "More settings"}</button>

          {more && (
            <div style={{ display: "grid", gap: 12, borderTop: `1px solid ${T.slate200}`, paddingTop: 12 }}>
              <div style={twoUp}>
                <div>
                  <label style={fieldLabel}>Column</label>
                  <input
                    style={inputBase}
                    value={form.track}
                    list="onb-track-options"
                    placeholder="Leave blank for one column"
                    onChange={(e) => set({ track: e.target.value })}
                  />
                  <datalist id="onb-track-options">
                    {trackOptions.map(t => <option key={t} value={t} />)}
                  </datalist>
                </div>
                <div>
                  <label style={fieldLabel}>Column position</label>
                  <input
                    style={inputBase} type="number" value={form.track_order}
                    onChange={(e) => set({ track_order: e.target.value })}
                  />
                </div>
              </div>

              <div>
                <label style={fieldLabel}>Order in the phase</label>
                <input
                  style={inputBase} type="number" value={form.sort_order}
                  onChange={(e) => set({ sort_order: e.target.value })}
                />
                <div style={{ fontSize: 11, color: T.slate500, marginTop: 4 }}>
                  Lower goes first. The arrows on the page set this for you.
                </div>
              </div>

              <div>
                <label style={fieldLabel}>Waits on</label>
                {blockerOptions.length === 0 ? (
                  <div style={{ fontSize: 12, color: T.slate500 }}>Nothing earlier to wait on.</div>
                ) : (
                  <div style={{
                    maxHeight: 170, overflowY: "auto", border: `1px solid ${T.slate200}`,
                    borderRadius: 8, padding: "8px 10px", boxSizing: "border-box", display: "grid", gap: 5,
                  }}>
                    {blockerOptions.map(b => (
                      <label key={b.id} style={{ display: "flex", gap: 8, alignItems: "flex-start", fontSize: 12, color: T.slate700, lineHeight: 1.4 }}>
                        <input
                          type="checkbox"
                          checked={form.blocked_by.includes(b.template_key)}
                          onChange={() => toggle("blocked_by", b.template_key)}
                          style={{ marginTop: 2, width: 15, height: 15, flexShrink: 0 }}
                        />
                        <span>{b.title}</span>
                      </label>
                    ))}
                  </div>
                )}
                <div style={{ fontSize: 11, color: T.slate500, marginTop: 4 }}>
                  The step stays greyed out on a plan until these are ticked.
                </div>
              </div>

              <div>
                <label style={fieldLabel}>Opens</label>
                <select style={inputBase} value={form.unlock_rule} onChange={(e) => set({ unlock_rule: e.target.value })}>
                  <option value="">As soon as what it waits on is done</option>
                  <option value="friday_before_start">Friday before they start</option>
                </select>
              </div>

              <div>
                <label style={fieldLabel}>Who it applies to</label>
                <div style={{ display: "grid", gap: 8 }}>
                  <Chips options={targetOptions.cats} selected={form.applies_to_role_categories} onToggle={(v) => toggle("applies_to_role_categories", v)} />
                  <Chips options={targetOptions.roles} selected={form.applies_to_roles} onToggle={(v) => toggle("applies_to_roles", v)} />
                  <Chips options={targetOptions.levels} selected={form.applies_to_role_levels} onToggle={(v) => toggle("applies_to_role_levels", v)} />
                </div>
                <div style={{ fontSize: 11, color: T.slate500, marginTop: 6 }}>
                  Nothing picked means everyone gets it.
                </div>
              </div>

              <div>
                <label style={fieldLabel}>Key</label>
                <input
                  style={{ ...inputBase, fontFamily: "ui-monospace, monospace", fontSize: 12 }}
                  value={effectiveKey}
                  onChange={(e) => { setKeyTouched(true); set({ template_key: e.target.value }); }}
                />
                <div style={{ fontSize: 11, color: T.slate500, marginTop: 4 }}>
                  How other steps point at this one. Renaming it updates them too.
                </div>
              </div>

              <div>
                <label style={fieldLabel}>Notes</label>
                <textarea
                  style={{ ...inputBase, minHeight: 52, resize: "vertical", fontFamily: "inherit" }}
                  value={form.notes}
                  placeholder="For you, not shown on the plan."
                  onChange={(e) => set({ notes: e.target.value })}
                />
              </div>
            </div>
          )}
        </div>

        {err && (
          <div style={{ marginTop: 12, background: T.redLt, color: T.red, fontSize: 12, padding: "8px 10px", borderRadius: 8 }}>
            {err}
          </div>
        )}

        <div style={{
          display: "flex", justifyContent: "space-between", alignItems: "center",
          gap: 8, flexWrap: "wrap", marginTop: 16,
          borderTop: `1px solid ${T.slate200}`, paddingTop: 14,
        }}>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            {!isNew && (
              <Button variant="danger" disabled={busy} onClick={remove}>Delete</Button>
            )}
          </div>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            <Button variant="secondary" disabled={busy} onClick={onClose}>Cancel</Button>
            <Button variant="primary" disabled={busy} onClick={save}>{busy ? "Saving…" : "Save"}</Button>
          </div>
        </div>
      </div>
    </div>
  );
}

// ─── main tab ───────────────────────────────────────
export default function OnboardingTemplateEditor({ phaseMeta, ownerName, team = [], phases = [], canEdit = false }) {
  const vp = useViewport();
  const [state, setState] = useState({ loading: true, error: null, rows: [] });
  const [editingId, setEditingId, stepHref] = useTabParam("step", null);
  const [addPhase, setAddPhase] = useState(null);
  const [moveErr, setMoveErr] = useState("");

  const load = useCallback(async () => {
    if (!supabase || !AGENCY_ID) {
      setState({ loading: false, error: "Supabase not configured.", rows: [] });
      return;
    }
    const { data, error } = await supabase
      .from("onboarding_step_templates")
      .select(COLS)
      .eq("agency_id", AGENCY_ID)
      .order("phase", { ascending: true })
      .order("sort_order", { ascending: true });
    setState({ loading: false, error: error ? error.message : null, rows: data || [] });
  }, []);

  useEffect(() => { load(); }, [load]);

  const rows = state.rows;
  const activeRows = useMemo(() => rows.filter(r => r.is_active), [rows]);
  const retiredCount = rows.length - activeRows.length;
  // Every row is on the page. Nothing sits behind a toggle — a step that is
  // not wanted gets deleted, not tucked away where it can come back.
  const visibleRows = rows;

  const people = useMemo(
    () => (team || [])
      .filter(t => t.is_active !== false && !t.archived_at && !t.is_test_user)
      .sort((a, b) => personName(a).localeCompare(personName(b))),
    [team]
  );

  const phaseOptions = useMemo(() => {
    const map = new Map();
    (phases || []).forEach(p => map.set(p.phase, { phase: p.phase, name: p.name, is_active: true }));
    rows.forEach(r => {
      if (!map.has(r.phase)) {
        const meta = phaseMeta(r.phase);
        map.set(r.phase, { phase: r.phase, name: meta.name, is_active: false });
      }
    });
    return [...map.values()].sort((a, b) => a.phase - b.phase);
  }, [phases, rows, phaseMeta]);

  // Every phase that has steps, plus every live phase so an empty one can
  // still be filled in.
  const phaseList = useMemo(() => {
    const s = new Set(visibleRows.map(r => r.phase));
    (phases || []).forEach(p => s.add(p.phase));
    return [...s].sort((a, b) => a - b);
  }, [visibleRows, phases]);

  const titleByKey = useMemo(
    () => new Map(rows.map(r => [r.template_key, r.title])),
    [rows]
  );

  const editingRow = useMemo(() => {
    if (!editingId) return null;
    if (editingId === NEW_ID) {
      const phase = addPhase != null ? addPhase : (phaseOptions[0]?.phase ?? 10);
      const sibs = rows.filter(r => r.phase === phase);
      const last = sibs.length ? sibs[sibs.length - 1] : null;
      return {
        id: null, template_key: "", title: "", description: "", substeps: null,
        phase, category: last?.category || "training",
        owner_kind: "new_hire", assigned_to: null,
        is_required: true,
        track: sibs.length && sibs.every(s => s.track === sibs[0].track) ? sibs[0].track : null,
        track_order: last?.track_order || 0,
        sort_order: sibs.reduce((m, s) => Math.max(m, s.sort_order || 0), 0) + 10,
        blocked_by: null, unlock_rule: null, applies_to_roles: null,
        applies_to_role_categories: null, applies_to_role_levels: null,
        notes: "", is_active: true,
      };
    }
    return rows.find(r => r.id === editingId) || null;
  }, [editingId, addPhase, rows, phaseOptions]);

  // Arrows renumber the whole column so a duplicated sort_order cannot
  // quietly freeze a step in place.
  const move = useCallback(async (row, dir) => {
    setMoveErr("");
    const sibs = visibleRows
      .filter(r => r.phase === row.phase && (r.track || null) === (row.track || null))
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));
    const i = sibs.findIndex(s => s.id === row.id);
    const j = i + dir;
    if (i < 0 || j < 0 || j >= sibs.length) return;
    const next = sibs.slice();
    next[i] = sibs[j];
    next[j] = sibs[i];
    const writes = next
      .map((s, ix) => ({ id: s.id, sort_order: (ix + 1) * 10, was: s.sort_order }))
      .filter(u => u.was !== u.sort_order);
    const results = await Promise.all(writes.map(u =>
      supabase.from("onboarding_step_templates")
        .update({ sort_order: u.sort_order, updated_at: new Date().toISOString() })
        .eq("id", u.id)
    ));
    const bad = results.find(r => r.error);
    if (bad) { setMoveErr(bad.error.message); return; }
    await load();
  }, [visibleRows, load]);

  // A ?step= carried in from somewhere else should not sit in the URL doing
  // nothing once the rows are in.
  useEffect(() => {
    if (state.loading || !editingId || editingId === NEW_ID) return;
    if (!rows.some(r => r.id === editingId)) setEditingId(null);
  }, [state.loading, editingId, rows, setEditingId]);

  const openNew = (phase) => { setAddPhase(phase); setEditingId(NEW_ID); };
  const closeEditor = () => { setEditingId(null); setAddPhase(null); };

  if (state.loading) {
    return <div style={{ padding: 30, textAlign: "center", color: T.slate500, fontSize: 13 }}>Loading template…</div>;
  }
  if (state.error) {
    return <Card style={{ background: T.redLt }}><div style={{ color: T.red, fontSize: 12 }}>{state.error}</div></Card>;
  }

  const renderRow = (r, sibs) => {
    const cat = CATEGORY_COLORS[r.category] || { fg: T.slate700, bg: T.slate100, label: r.category || "Step" };
    const groups = subGroups(r.substeps, { keepEmpty: true });
    const after = (r.blocked_by || []).map(k => titleByKey.get(k) || k);
    const idx = sibs.findIndex(s => s.id === r.id);
    const arrow = {
      width: 22, height: 20, lineHeight: "18px", padding: 0, fontSize: 11,
      borderRadius: 5, boxSizing: "border-box", background: T.white,
      border: `1px solid ${T.slate200}`, color: T.slate500, cursor: "pointer",
    };
    return (
      <div
        key={r.id}
        onClick={canEdit ? () => setEditingId(r.id) : undefined}
        style={{
          border: `1px solid ${T.slate200}`, borderRadius: 8,
          padding: "10px 12px", boxSizing: "border-box", ...wrapLongText,
          background: r.is_active ? T.white : T.slate50,
          opacity: r.is_active ? 1 : 0.72,
          cursor: canEdit ? "pointer" : "default",
        }}
      >
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 8 }}>
          <div style={{ fontSize: 13, fontWeight: 600, color: T.slate900, lineHeight: 1.4, minWidth: 0 }}>
            {canEdit ? (
              <TabLink
                href={stepHref(r.id)}
                onSelect={() => setEditingId(r.id)}
                style={{ color: T.slate900, textDecoration: "none", fontWeight: 600 }}
              >{r.title}</TabLink>
            ) : r.title}
            {!r.is_required && (
              <span style={{ marginLeft: 8, fontSize: 10, color: T.slate400, fontWeight: 500 }}>optional</span>
            )}
            {!r.is_active && (
              <span style={{ marginLeft: 8, fontSize: 10, color: T.red, fontWeight: 700 }}>retired — delete me</span>
            )}
          </div>
          <div style={{ display: "flex", gap: 4, flexShrink: 0, flexWrap: "wrap", justifyContent: "flex-end", alignItems: "center" }}>
            {r.owner_kind !== "new_hire" && (
              <Pill fg={T.purple} bg={T.purpleLt}>{ownerName(r)}</Pill>
            )}
            <Pill fg={cat.fg} bg={cat.bg}>{cat.label}</Pill>
            {canEdit && sibs.length > 1 && (
              <span style={{ display: "flex", gap: 2 }} onClick={(e) => e.stopPropagation()}>
                <button style={arrow} title="Move up" disabled={idx <= 0}
                  onClick={() => move(r, -1)}>↑</button>
                <button style={arrow} title="Move down" disabled={idx < 0 || idx >= sibs.length - 1}
                  onClick={() => move(r, 1)}>↓</button>
              </span>
            )}
          </div>
        </div>
        {r.description && (
          <div style={{ fontSize: 11, color: T.slate500, marginTop: 3, lineHeight: 1.45 }}>{r.description}</div>
        )}
        {groups.map((g, gi) => (
          <div key={gi} style={{ marginTop: 8 }}>
            {(g.group || g.altFor) && (
              <div style={{
                fontSize: 10, fontWeight: 700, color: T.slate500,
                textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 3,
              }}>{g.group || "Archived"}{g.altFor && (
                <span style={{ textTransform: "none", fontWeight: 500 }}> — instead of: {g.altFor}</span>
              )}</div>
            )}
            <ul style={{ margin: 0, paddingLeft: 18, display: "grid", gap: 3 }}>
              {g.fill === "team_list" && (
                <li style={{ fontSize: 12, color: T.slate500, lineHeight: 1.4, fontStyle: "italic" }}>
                  Every teammate, filled in from the team list
                </li>
              )}
              {g.items.map((label2, ix) => (
                <li key={ix} style={{ fontSize: 12, color: T.slate700, lineHeight: 1.4 }}>
                  <LabelText text={label2} pathColor={T.teal} linkColor={T.blue} />
                </li>
              ))}
            </ul>
          </div>
        ))}
        {r.widget === "team_forms" && (
          <div style={{ marginTop: 8 }} onClick={(e) => e.stopPropagation()}>
            <div style={{
              fontSize: 10, fontWeight: 700, color: T.slate500,
              textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 3,
            }}>Forms on the site</div>
            <ul style={{ margin: 0, paddingLeft: 18, display: "grid", gap: 3 }}>
              {FORMS.map(f => (
                <li key={f.id} style={{ fontSize: 12, lineHeight: 1.4 }}>
                  <a href={`/development?area=forms&form=${f.id}`} style={{ color: T.blue }}>{f.label}</a>
                </li>
              ))}
            </ul>
          </div>
        )}
        {r.unlock_rule === "friday_before_start" && (
          <div style={{ fontSize: 10, color: T.amber, marginTop: 8, fontWeight: 600 }}>
            Opens the Friday before they start
          </div>
        )}
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

  const addRow = (phase) => (
    <button
      onClick={() => openNew(phase)}
      style={{
        width: "100%", boxSizing: "border-box", padding: "9px 12px",
        border: `1px dashed ${T.slate300}`, borderRadius: 8, background: "transparent",
        color: T.slate500, fontSize: 12, fontWeight: 600, cursor: "pointer", textAlign: "left",
      }}
    >+ Add step</button>
  );

  return (
    <div>
      <Card style={{ marginBottom: 14, background: T.blueLt, border: `1px solid ${T.blue}` }}>
        <div style={{ display: "flex", justifyContent: "space-between", gap: 10, flexWrap: "wrap", alignItems: "center" }}>
          <div style={{ fontSize: 12, color: T.slate800, lineHeight: 1.55, flex: "1 1 260px" }}>
            {activeRows.length} steps. Creating a plan copies the ones that match that person's role into their own
            checklist. Changes here flow into plans that are already running, and ticked boxes stay ticked.
          </div>
          {canEdit && retiredCount > 0 && (
            <div style={{ fontSize: 12, color: T.red, fontWeight: 600, flex: "0 1 auto" }}>
              {retiredCount} retired {retiredCount === 1 ? "step is" : "steps are"} still
              sitting in the table. They go into no plan. Open one and delete it.
            </div>
          )}
        </div>
      </Card>

      {moveErr && (
        <Card style={{ marginBottom: 12, background: T.redLt }}>
          <div style={{ color: T.red, fontSize: 12 }}>{moveErr}</div>
        </Card>
      )}

      {phaseList.length === 0 && (
        <Card>
          <div style={{ fontSize: 14, fontWeight: 600, color: T.slate800, marginBottom: 6 }}>No template steps yet</div>
          <div style={{ fontSize: 12, color: T.slate500 }}>Nothing is set up in the step library, so a new plan would come out empty.</div>
        </Card>
      )}

      {phaseList.map(ph => {
        const phRows = visibleRows.filter(r => r.phase === ph);
        const label = phaseMeta(ph);
        const cols = trackColumns(phRows);
        const gridStyle = {
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))",
          gap: cols ? 16 : 10, alignItems: "start",
        };
        return (
          <Card key={ph} style={{ marginBottom: 12, padding: vp.isPhone ? "14px 12px" : "16px 18px" }}>
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
              <div style={{ fontSize: 11, color: T.slate500 }}>{phRows.length} steps</div>
            </div>

            {cols ? (
              <div style={gridStyle}>
                {cols.map(c => (
                  <div key={c.name || "_"} style={{ display: "grid", gap: 10, alignContent: "start", minWidth: 0 }}>
                    {c.name && <div style={trackHeadStyle}>{c.name}</div>}
                    {c.steps.map(r => renderRow(r, c.steps))}
                  </div>
                ))}
              </div>
            ) : (
              <div style={gridStyle}>{phRows.map(r => renderRow(r, phRows))}</div>
            )}

            {canEdit && <div style={{ marginTop: 10 }}>{addRow(ph)}</div>}
          </Card>
        );
      })}

      {canEdit && editingRow && (
        <StepEditor
          row={editingRow}
          isNew={editingId === NEW_ID}
          rows={rows}
          phaseOptions={phaseOptions}
          people={people}
          onClose={closeEditor}
          onSaved={load}
        />
      )}
    </div>
  );
}
