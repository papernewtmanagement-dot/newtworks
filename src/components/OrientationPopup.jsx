import { useCallback, useEffect, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import {
  PopupShell, Button, GroupHead, ItemInfo, LabelText, inputBase,
  subGroups, subAll, splitIndent, substepsToText, textToSubsteps, wrapLongText, fmtDate, setSubstepDone,
} from "../lib/onboardingUi.jsx";
import { Section, Check } from "./TeamForms.jsx";

// =========================================================================
// OrientationPopup.jsx
// =========================================================================
// Peter's orientation. Opened from the (i) next to the Orientation line on
// the Review With Peter card; only the owner sees that (i). The talking
// points live in onboarding_instructions (kind "orientation"), written in
// the sub-item text format, and Peter edits them right here. At the bottom
// there is one checkmark per new hire: checking one ticks the Orientation
// line on that hire's card, and unchecking unticks it. The database lets
// nobody but the owner tick that line (onboarding_step_complete_gate).
// =========================================================================

export default function OrientationPopup({ instruction, userId, onClose }) {
  const vp = useViewport();
  const pad = vp.isPhone ? "18px 14px" : "22px 26px";
  const todayCT = new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
  const label = instruction?.substep_label || "Orientation";
  const [body, setBody] = useState(instruction?.body_md || "");
  const [draft, setDraft] = useState(null);   // text being edited, null when not editing
  const [saving, setSaving] = useState(false);
  const [hires, setHires] = useState(null);   // null while loading
  const [busy, setBusy] = useState(null);     // the card being saved
  const [err, setErr] = useState("");

  // Every new hire whose plan is running and has a card with this line.
  const load = useCallback(async () => {
    if (!supabase || !AGENCY_ID) { setHires([]); return; }
    const [plansRes, namesRes] = await Promise.all([
      supabase.from("team_onboarding_plans")
        .select("id, start_date")
        .eq("agency_id", AGENCY_ID)
        .in("status", ["active", "paused"]),
      supabase.rpc("onboarding_visible_plan_names"),
    ]);
    if (plansRes.error) { setErr(plansRes.error.message); setHires([]); return; }
    const plans = new Map((plansRes.data || []).map(p => [p.id, p]));
    if (!plans.size) { setHires([]); return; }
    const { data: cards, error: cardsErr } = await supabase.from("team_onboarding_steps")
      .select("id, plan_id, substeps, substeps_done, completed_at")
      .in("plan_id", [...plans.keys()]);
    if (cardsErr) { setErr(cardsErr.message); setHires([]); return; }
    const names = {};
    (namesRes.data || []).forEach(r => { names[r.plan_id] = r.subject_name; });
    const list = (cards || [])
      .filter(c => subAll(c.substeps).includes(label))
      .map(c => ({
        step: c,
        name: names[c.plan_id] || "New hire",
        startDate: plans.get(c.plan_id)?.start_date || null,
        done: Array.isArray(c.substeps_done) && c.substeps_done.includes(label),
      }))
      .sort((a, b) => String(a.startDate || "").localeCompare(String(b.startDate || ""))
        || a.name.localeCompare(b.name));
    setHires(list);
  }, [label]);

  useEffect(() => { load(); }, [load]);

  const toggle = async (h) => {
    setErr("");
    setBusy(h.step.id);
    const { error } = await setSubstepDone(h.step, label, !h.done, userId);
    setBusy(null);
    if (error) { setErr(error.message); return; }
    await load();
  };

  // Saved in the same text format as sub-items, cleaned up the same way.
  const save = async () => {
    setErr("");
    setSaving(true);
    const text = substepsToText(textToSubsteps(draft || ""));
    const { error } = await supabase.from("onboarding_instructions")
      .update({ body_md: text, updated_at: new Date().toISOString() })
      .eq("id", instruction.id);
    setSaving(false);
    if (error) { setErr(error.message); return; }
    setBody(text);
    setDraft(null);
  };

  const groups = subGroups(textToSubsteps(body));

  return (
    <PopupShell onClose={onClose}>
      <div style={{ padding: pad, minWidth: 0, ...wrapLongText }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap", paddingRight: 30 }}>
          <div style={{ fontSize: 19, fontWeight: 700, color: T.slate900, letterSpacing: "-0.01em" }}>
            {instruction?.title || "Orientation"}
          </div>
          {draft === null && (
            <Button variant="secondary" onClick={() => setDraft(substepsToText(textToSubsteps(body)))}>Edit</Button>
          )}
        </div>

        {draft !== null ? (
          <div style={{ marginTop: 16 }}>
            <div style={{ fontSize: 12, color: T.slate500, marginBottom: 6, lineHeight: 1.5 }}>
              One point per line. A line ending in a colon starts a new section.
            </div>
            <textarea value={draft} onChange={(e) => setDraft(e.target.value)} rows={vp.isPhone ? 16 : 22}
              style={{ ...inputBase, resize: "vertical", fontFamily: "inherit", lineHeight: 1.5 }} />
            <div style={{ marginTop: 10, display: "flex", gap: 8, flexWrap: "wrap" }}>
              <Button onClick={save} disabled={saving}>{saving ? "Saving…" : "Save"}</Button>
              <Button variant="secondary" onClick={() => setDraft(null)} disabled={saving}>Cancel</Button>
            </div>
          </div>
        ) : groups.map((g, gi) => (
          <div key={gi} style={{ marginTop: gi === 0 ? 16 : 26 }}>
            {(g.group || g.info.length > 0) && (
              <GroupHead
                label={g.group}
                info={g.info}
                style={{ marginBottom: 8 }}
                labelStyle={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}
                pathColor={T.teal} linkColor={T.blue}
              />
            )}
            <ul style={{ margin: 0, paddingLeft: 20, display: "grid", gap: 6 }}>
              {g.items.map((line, ix) => {
                const { level, text } = splitIndent(line);
                return (
                  <li key={ix} style={{ fontSize: 13.5, color: T.slate800, lineHeight: 1.5, marginLeft: level * 18 }}>
                    <ItemInfo lines={g.itemInfo[line] || []} pathColor={T.teal} linkColor={T.blue}>
                      <LabelText text={text} pathColor={T.teal} linkColor={T.blue} />
                    </ItemInfo>
                  </li>
                );
              })}
            </ul>
          </div>
        ))}

        <Section title="Who was there" note={`Checking someone off ticks ${label} on their plan.`}>
          {hires === null ? (
            <div style={{ fontSize: 13, color: T.slate500 }}>Loading…</div>
          ) : hires.length === 0 ? (
            <div style={{ fontSize: 13, color: T.slate500 }}>No new hires right now.</div>
          ) : (
            <div style={{ display: "grid", gap: 8 }}>
              {hires.map(h => (
                <Check key={h.step.id} checked={h.done} disabled={busy === h.step.id}
                  onChange={() => toggle(h)}>
                  {h.name}
                  <span style={{ color: T.slate500 }}>
                    {h.startDate ? ` · ${h.startDate > todayCT ? "starts" : "started"} ${fmtDate(h.startDate)}` : ""}
                  </span>
                </Check>
              ))}
            </div>
          )}
          {err && (
            <div style={{
              marginTop: 10, padding: "10px 12px", background: T.redLt, color: T.red,
              borderRadius: 8, fontSize: 13, boxSizing: "border-box",
            }}>{err}</div>
          )}
        </Section>

        <div style={{ marginTop: 22 }}>
          <Button variant="secondary" onClick={onClose}>Done</Button>
        </div>
      </div>
    </PopupShell>
  );
}
