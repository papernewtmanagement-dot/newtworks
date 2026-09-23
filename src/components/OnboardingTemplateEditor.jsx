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
  subGroups, substepsToText, textToSubsteps, trackColumns, wrapLongText, LabelText, GroupHead, ItemInfo,
  splitIndent, columnStyle, bannerStyle, weeksLabel,
} from "../lib/onboardingUi.jsx";

const COLS = "id, template_key, title, description, phase, category, applies_to_roles, applies_to_role_categories, applies_to_role_levels, is_required, sort_order, notes, substeps, owner_kind, assigned_to, track, track_order, blocked_by, is_active, unlock_rule, widget, assign_role_category, weeks, full_width, updated_at";

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
function StepEditor({ row, isNew, rows, phaseOptions, people, onClose, onSaved, weeksOf = () => [] }) {
  const vp = useViewport();
  const [form, setForm] = useState(() => ({
    template_key: row.template_key || "",
    title: row.title || "",
    description: row.description || "",
    subText: substepsToText(row.substeps),
    phase: row.phase,
    category: row.category || "training",
    owner: ownerValue(row),
    assign_role_category: row.assign_role_category || "",
    is_required: row.is_required !== false,
    weeks: Array.isArray(row.weeks) ? row.weeks : [],
    full_width: !!row.full_width,
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
  const [instrOrig, setInstrOrig] = useState("");
  const [instrOpen, setInstrOpen] = useState(false);
  useEffect(() => {
    if (isNew || !row.title) return undefined;
    let cancelled = false;
    supabase.from("onboarding_instructions")
      .select("id, body_md")
      .eq("agency_id", AGENCY_ID)
      .eq("substep_label", row.title)
      .maybeSingle()
      .then(({ data }) => {
        if (!cancelled && data) { setInstr({ id: data.id, text: data.body_md || "" }); setInstrOrig(data.body_md || ""); }
      });
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

  // The columns already in the chosen phase, left to right. Picking one puts
  // the step in that column's place and at the bottom of it, so nobody has to
  // know the column's position number.
  const phaseColumns = useMemo(() => {
    const m = new Map();
    rows.forEach(r => {
      if (Number(r.phase) === Number(form.phase) && r.track && !m.has(r.track)) m.set(r.track, r.track_order || 0);
    });
    return [...m.entries()]
      .map(([name, order]) => ({ name, order }))
      .sort((a, b) => a.order - b.order || a.name.localeCompare(b.name));
  }, [rows, form.phase]);
  const [newCol, setNewCol] = useState(false);
  const pickColumn = (v) => {
    if (v === "__new") {
      setNewCol(true);
      set({ track: "", track_order: Math.max(0, ...phaseColumns.map(c => c.order)) + 1 });
      return;
    }
    setNewCol(false);
    if (!v) { set({ track: "", track_order: 0 }); return; }
    const c = phaseColumns.find(x => x.name === v);
    const patchCol = { track: v, track_order: c ? c.order : 0 };
    if (v !== (row.track || "")) {
      const inCol = rows.filter(r => Number(r.phase) === Number(form.phase) && r.track === v && r.id !== row.id);
      patchCol.sort_order = Math.max(0, ...inCol.map(r => r.sort_order || 0)) + 10;
    }
    set(patchCol);
  };
  // The weeks of the chosen card, when it spans more than one.
  const weekList = weeksOf(Number(form.phase));
  const toggleWeek = (w) => {
    const cur = form.weeks.length ? form.weeks : weekList;
    const next = cur.includes(w) ? cur.filter(x => x !== w) : [...cur, w];
    if (!next.length) return; // a subcard is in at least one week
    set({ weeks: next.length >= weekList.length ? [] : next.sort((a, b) => a - b) });
  };
  // One copy of this subcard per week it is in, each limited to its week.
  const splitByWeek = async () => {
    const ws = (form.weeks.length ? form.weeks : weekList).slice().sort((a, b) => a - b);
    if (ws.length < 2) return;
    if (!window.confirm(`Make a separate copy of this subcard for each of its ${ws.length} weeks? Each copy starts as the saved version.`)) return;
    setBusy(true); setErr("");
    try {
      const base = rows.find(r => r.id === row.id) || row;
      const taken = new Set(rows.map(r => r.template_key));
      const copies = ws.slice(1).map(w => {
        const { id: _id, updated_at: _u, ...rest } = base;
        let key = `${base.template_key}_w${w}`;
        for (let n = 2; taken.has(key); n++) key = `${base.template_key}_w${w}_${n}`;
        taken.add(key);
        return { ...rest, agency_id: AGENCY_ID, template_key: key, weeks: [w] };
      });
      const { error: e1 } = await supabase.from("onboarding_step_templates").insert(copies);
      if (e1) throw e1;
      const { error: e2 } = await supabase.from("onboarding_step_templates")
        .update({ weeks: [ws[0]], updated_at: new Date().toISOString() }).eq("id", row.id);
      if (e2) throw e2;
      await onSaved();
      onClose();
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setBusy(false);
    }
  };
  const roleGroups = useMemo(
    () => [...new Set(people.map(p => p.role_category).filter(Boolean))].sort(),
    [people]
  );

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
      // every week (null) unless only some of the card's weeks are picked
      weeks: (() => {
        const all = weeksOf(Number(form.phase));
        const picked = form.weeks.filter(w => all.includes(w)).sort((a, b) => a - b);
        return picked.length && picked.length < all.length ? picked : null;
      })(),
      full_width: !!form.full_width,
      assign_role_category: form.assign_role_category || null,
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

    // Say so when the save would change nothing, instead of closing as if it
    // had: blank lines and spaces at the end of a line are not kept.
    if (!isNew) {
      const canon = (v) => JSON.stringify(v ?? null, (k, val) => (
        val && typeof val === "object" && !Array.isArray(val)
          ? Object.fromEntries(Object.entries(val).sort(([a], [b]) => a.localeCompare(b)))
          : val));
      const changed = Object.keys(patch).some(k => k !== "updated_at" && canon(patch[k]) !== canon(row[k]))
        || instr.text.trim() !== instrOrig.trim();
      if (!changed) {
        setErr("Nothing changed, so there was nothing to save. Blank lines and spaces at the end of a line are not kept.");
        return;
      }
    }

    setBusy(true);
    try {
      if (isNew) {
        const { error } = await supabase
          .from("onboarding_step_templates")
          .insert({ ...patch, agency_id: AGENCY_ID, is_active: true });
        if (error) throw error;
      } else {
        // Only save over the version that was opened. If the step changed
        // since (a migration, another tab), nothing is written, so an old
        // copy in this form can never put back what was taken out.
        const { data: saved, error } = await supabase
          .from("onboarding_step_templates")
          .update(patch)
          .eq("id", row.id)
          .eq("updated_at", row.updated_at)
          .select("id");
        if (error) throw error;
        if (!saved || !saved.length) {
          throw new Error("This step changed after you opened it, so nothing was saved. Close it, open it again, and make your edit on the latest version.");
        }

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
              Start a line with two spaces to nest it under the line above.
              A line starting with &gt; goes behind an (i): on the heading when it sits right under the heading, otherwise on the line above it.
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

          <div style={twoUp}>
            <div>
              <label style={fieldLabel}>Also assign</label>
              <select style={inputBase} value={form.assign_role_category}
                onChange={(e) => set({ assign_role_category: e.target.value })}>
                <option value="">Nobody else</option>
                {roleGroups.map(g => <option key={g} value={g}>{`${g} team`}</option>)}
              </select>
            </div>
            <div>
              <label style={fieldLabel}>Column</label>
              <select style={inputBase} value={newCol ? "__new" : (form.track || "")}
                onChange={(e) => pickColumn(e.target.value)}>
                <option value="">No column</option>
                {phaseColumns.map(c => <option key={c.name} value={c.name}>{c.name}</option>)}
                {form.track && !newCol && !phaseColumns.some(c => c.name === form.track) && (
                  <option value={form.track}>{form.track}</option>
                )}
                <option value="__new">New column…</option>
              </select>
              {newCol && (
                <input style={{ ...inputBase, marginTop: 6 }} placeholder="New column name"
                  value={form.track} onChange={(e) => set({ track: e.target.value })} />
              )}
            </div>
          </div>

          {weekList.length > 1 && (
            <div>
              <label style={fieldLabel}>Weeks</label>
              <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                {weekList.map(w => {
                  const on = form.weeks.length === 0 || form.weeks.includes(w);
                  return (
                    <button key={w} type="button" onClick={() => toggleWeek(w)} style={{
                      padding: "5px 10px", borderRadius: 999, fontSize: 12, cursor: "pointer",
                      border: `1px solid ${on ? T.teal : T.slate200}`,
                      background: on ? T.tealLt : T.white, color: on ? T.teal : T.slate500,
                    }}>Week {w}</button>
                  );
                })}
              </div>
              <div style={{ fontSize: 11, color: T.slate500, marginTop: 6, lineHeight: 1.5 }}>
                All lit means every week. Each week on a plan gets its own copy.
                {!isNew && (form.weeks.length === 0 || form.weeks.length > 1) && (
                  <>{" "}<button type="button" onClick={splitByWeek} disabled={busy} style={{
                    background: "none", border: "none", padding: 0, color: T.blue,
                    fontSize: 11, fontWeight: 600, cursor: "pointer",
                  }}>Split by week</button> to edit one week on its own.</>
                )}
              </div>
            </div>
          )}

          <button
            onClick={() => setMore(m => !m)}
            style={{
              background: "transparent", border: "none", padding: 0, cursor: "pointer",
              fontSize: 12, fontWeight: 600, color: T.blue, textAlign: "left",
            }}
          >{more ? "Hide extra settings" : "More settings"}</button>

          {more && (
            <div style={{ display: "grid", gap: 12, borderTop: `1px solid ${T.slate200}`, paddingTop: 12 }}>
              <label style={{ display: "flex", gap: 8, alignItems: "center", fontSize: 13, color: T.slate700 }}>
                <input type="checkbox" checked={form.full_width}
                  onChange={(e) => set({ full_width: e.target.checked })} />
                Show across the top of the card, like Goals
              </label>
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
export default function OnboardingTemplateEditor({ phaseMeta, ownerName, team = [], phases = [], canEdit = false, onPhasesChanged }) {
  const vp = useViewport();
  const [state, setState] = useState({ loading: true, error: null, rows: [] });
  const [phOpen, setPhOpen] = useState({});
  const [editingPhase, setEditingPhase] = useState(null);

  // First week number of each major card (same database rule plans use).
  const [firstWeeks, setFirstWeeks] = useState({});
  useEffect(() => {
    if (!supabase || !AGENCY_ID) return;
    let alive = true;
    supabase.rpc("onboarding_phase_first_weeks", { p_agency_id: AGENCY_ID }).then(({ data }) => {
      if (alive && Array.isArray(data)) setFirstWeeks(Object.fromEntries(data.map(r => [r.phase, r.first_week])));
    });
    return () => { alive = false; };
  }, [phases]);
  const weeksOf = useCallback((ph) => {
    const row = (phases || []).find(p => p.phase === ph);
    const f = firstWeeks[ph];
    if (!row || row.stage !== "ramp" || !(row.weeks_long > 1) || !f) return [];
    return Array.from({ length: row.weeks_long }, (_, i) => f + i);
  }, [phases, firstWeeks]);
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

  // The current agency team, from the same database rule that fills the
  // team lists on each plan (there, minus the new hire).
  const [teamNames, setTeamNames] = useState([]);
  useEffect(() => {
    if (!supabase || !AGENCY_ID) return;
    let alive = true;
    supabase.rpc("onboarding_team_list_names", { p_agency_id: AGENCY_ID })
      .then(({ data }) => { if (alive) setTeamNames(Array.isArray(data) ? data : []); });
    return () => { alive = false; };
  }, [team]);

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
            {Array.isArray(r.weeks) && r.weeks.length > 0 && (
              <Pill fg={T.teal} bg={T.tealLt}>{weeksLabel(r.weeks)}</Pill>
            )}
            {Array.isArray(r.applies_to_role_categories) && r.applies_to_role_categories.length > 0 && (
              <Pill fg={T.slate600} bg={T.slate100}>{r.applies_to_role_categories.join(", ")}</Pill>
            )}
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
          <div style={{ fontSize: 11, color: T.slate500, marginTop: 3, lineHeight: 1.45 }}>
            <LabelText text={r.description} pathColor={T.teal} linkColor={T.blue} />
          </div>
        )}
        {groups.map((g, gi) => (
          <div key={gi} style={{ marginTop: 8 }}>
            {(g.group || g.altFor || g.info.length > 0) && (
              <GroupHead
                label={g.group || (g.altFor ? "Archived" : null)}
                info={g.info}
                extra={g.altFor ? (
                  <span style={{ fontSize: 10, color: T.slate500 }}>instead of: {g.altFor}</span>
                ) : null}
                style={{ marginBottom: 3 }}
                labelStyle={{
                  fontSize: 10, fontWeight: 700, color: T.slate500,
                  textTransform: "uppercase", letterSpacing: 0.4,
                }}
                pathColor={T.teal} linkColor={T.blue}
              />
            )}
            <ul style={{ margin: 0, paddingLeft: 18, display: "grid", gap: 3 }}>
              {g.fill === "team_list" && teamNames.map(n => (
                <li key={n} style={{ fontSize: 12, color: T.slate700, lineHeight: 1.4 }}>{n}</li>
              ))}
              {g.items.map((label2, ix) => {
                const { level, text: shown2 } = splitIndent(label2);
                return (
                  <li key={ix} style={{ fontSize: 12, color: T.slate700, lineHeight: 1.4, marginLeft: level * 16 }}>
                    <ItemInfo lines={g.itemInfo[label2] || []} pathColor={T.teal} linkColor={T.blue}>
                      <LabelText text={shown2} pathColor={T.teal} linkColor={T.blue} />
                    </ItemInfo>
                  </li>
                );
              })}
            </ul>
          </div>
        ))}
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
        const banners = phRows.filter(r => r.full_width);
        const rest = phRows.filter(r => !r.full_width);
        const cols = trackColumns(rest);
        // Folded unless opened, or unless a subcard in it is being edited.
        const open = phOpen[ph] ?? (!!editingRow && editingRow.phase === ph);
        const gridStyle = {
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))",
          gap: cols ? 12 : 10, alignItems: cols ? "stretch" : "start",
        };
        return (
          <Card key={ph} style={{ marginBottom: 12, padding: vp.isPhone ? "14px 12px" : "16px 18px" }}>
            <div
              role="button" tabIndex={0}
              onClick={() => setPhOpen(o => ({ ...o, [ph]: !open }))}
              onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); setPhOpen(o => ({ ...o, [ph]: !open })); } }}
              style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 10, marginBottom: open ? 10 : 0, flexWrap: "wrap", cursor: "pointer" }}
            >
              <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                <span style={{ fontSize: 11, color: T.slate400, width: 10 }}>{open ? "▾" : "▸"}</span>
                <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{label.name}</div>
                {label.stage && STAGE_LABELS[label.stage] && (
                  <Pill fg={STAGE_LABELS[label.stage].fg} bg={STAGE_LABELS[label.stage].bg}>
                    {STAGE_LABELS[label.stage].label}
                  </Pill>
                )}
                {open && label.blurb && <div style={{ fontSize: 11, color: T.slate500, flexBasis: "100%" }}>{label.blurb}</div>}
              </div>
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <div style={{ fontSize: 11, color: T.slate500 }}>
                  {label.weeksLong > 1 ? `${label.weeksLong} weeks · ` : ""}{phRows.length} steps
                </div>
                {canEdit && (
                  <Button variant="secondary" style={{ padding: "3px 10px", fontSize: 11 }}
                    onClick={(e) => { e.stopPropagation(); setEditingPhase(ph); }}>Edit</Button>
                )}
              </div>
            </div>

            {open && (
              <>
                {label.weeksLong > 1 && (
                  <div style={{ fontSize: 11, color: T.slate500, marginBottom: 10, lineHeight: 1.5 }}>
                    On a plan this becomes one card per week, each with these subcards. A subcard marked with a
                    week is only in that week; open a subcard and use Split by week to make one week different.
                  </div>
                )}
                {banners.length > 0 && (
                  <div style={bannerStyle}>{banners.map(r => renderRow(r, banners))}</div>
                )}
                {cols ? (
                  <div style={gridStyle}>
                    {cols.map((c, ci) => (
                      <div key={c.name || "_"} style={columnStyle(ci)}>
                        {c.name && <div style={trackHeadStyle}>{c.name}</div>}
                        {c.steps.map(r => renderRow(r, c.steps))}
                      </div>
                    ))}
                  </div>
                ) : (
                  <div style={gridStyle}>{rest.map(r => renderRow(r, rest))}</div>
                )}
                {canEdit && <div style={{ marginTop: 10 }}>{addRow(ph)}</div>}
              </>
            )}
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
          weeksOf={weeksOf}
        />
      )}

      {canEdit && editingPhase != null && (
        <PhaseEditor
          phase={editingPhase}
          row={(phases || []).find(p => p.phase === editingPhase)}
          firstWeek={firstWeeks[editingPhase]}
          onClose={() => setEditingPhase(null)}
          onSaved={async () => { if (onPhasesChanged) await onPhasesChanged(); await load(); }}
        />
      )}
    </div>
  );
}

// ─── the major-card editor ──────────────────────────
// Name, description, and for a weekly card how many weeks it spans and what
// each week is called. Changing the weeks moves the dates of later cards.
function PhaseEditor({ phase, row, firstWeek, onClose, onSaved }) {
  const [form, setForm] = useState({
    name: row?.name || "",
    blurb: row?.blurb || "",
    weeks_long: row?.weeks_long ?? "",
    titles: { ...(row?.week_titles || {}) },
  });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const isRamp = row?.stage === "ramp";
  const n = Math.max(0, Math.round(Number(form.weeks_long) || 0));
  const weekNums = isRamp && firstWeek && n > 1 ? Array.from({ length: n }, (_, i) => firstWeek + i) : [];

  const save = async () => {
    if (!form.name.trim()) { setErr("Give the card a name."); return; }
    setBusy(true); setErr("");
    try {
      const titles = Object.fromEntries(
        weekNums.map(w => [String(w), (form.titles[String(w)] || "").trim()]).filter(([, v]) => v));
      const patch = {
        name: form.name.trim(),
        blurb: form.blurb.trim() || null,
        week_titles: Object.keys(titles).length ? titles : null,
        updated_at: new Date().toISOString(),
      };
      if (isRamp) patch.weeks_long = n;
      const { error } = await supabase.from("onboarding_phases").update(patch)
        .eq("agency_id", AGENCY_ID).eq("phase", phase);
      if (error) throw error;
      await onSaved();
      onClose();
    } catch (e) {
      setErr(e.message || String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div onClick={onClose} style={{
      position: "fixed", inset: 0, zIndex: 1000, background: "rgba(15,23,42,0.45)",
      display: "flex", alignItems: "flex-start", justifyContent: "center",
      padding: "6vh 12px", boxSizing: "border-box", overflowY: "auto",
    }}>
      <div onClick={(e) => e.stopPropagation()} style={{
        width: "100%", maxWidth: 520, background: T.white, borderRadius: 12,
        padding: 18, boxSizing: "border-box", boxShadow: "0 20px 50px rgba(15,23,42,0.25)",
        display: "grid", gap: 12,
      }}>
        <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}>Edit card</div>
        <div>
          <label style={fieldLabel}>Name</label>
          <input style={inputBase} value={form.name} onChange={(e) => setForm(f => ({ ...f, name: e.target.value }))} />
        </div>
        <div>
          <label style={fieldLabel}>Description</label>
          <textarea style={{ ...inputBase, minHeight: 60, resize: "vertical" }} value={form.blurb}
            onChange={(e) => setForm(f => ({ ...f, blurb: e.target.value }))} />
        </div>
        {isRamp && (
          <div>
            <label style={fieldLabel}>How many weeks</label>
            <input style={{ ...inputBase, maxWidth: 120 }} type="number" min={0} value={form.weeks_long}
              onChange={(e) => setForm(f => ({ ...f, weeks_long: e.target.value }))} />
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 4 }}>
              More than one week and each week gets its own card on a plan. Changing this moves the dates of the cards after it.
            </div>
          </div>
        )}
        {weekNums.length > 0 && (
          <div>
            <label style={fieldLabel}>Week names</label>
            <div style={{ display: "grid", gap: 6 }}>
              {weekNums.map(w => (
                <div key={w} style={{ display: "flex", gap: 8, alignItems: "center" }}>
                  <span style={{ fontSize: 12, color: T.slate600, width: 64, flexShrink: 0 }}>Week {w}</span>
                  <input style={inputBase} placeholder="Optional" value={form.titles[String(w)] || ""}
                    onChange={(e) => setForm(f => ({ ...f, titles: { ...f.titles, [String(w)]: e.target.value } }))} />
                </div>
              ))}
            </div>
          </div>
        )}
        {err && <div style={{ fontSize: 12, color: T.red }}>{err}</div>}
        <div style={{ display: "flex", justifyContent: "flex-end", gap: 8 }}>
          <Button variant="secondary" disabled={busy} onClick={onClose}>Cancel</Button>
          <Button disabled={busy} onClick={save}>{busy ? "Saving…" : "Save"}</Button>
        </div>
      </div>
    </div>
  );
}
