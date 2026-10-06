import { useCallback, useEffect, useRef, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import {
  PopupShell, Button, GroupHead, ItemInfo, LabelText, inputBase, asksForReply,
  subGroups, subAll, splitIndent, substepsToText, textToSubsteps, wrapLongText, fmtDate, setSubstepDone,
} from "../lib/onboardingUi.jsx";
import { Section, Check } from "./TeamForms.jsx";

// =========================================================================
// OrientationPopup.jsx
// =========================================================================
// Peter's orientation. Opened from the (i) next to the Orientation line on
// the Review With Peter card; only the owner sees that (i). The script lives
// in onboarding_instructions (kind "orientation"), written in the sub-item
// text format, and Peter edits it right here.
//
// The script is a checklist. Peter checks who is here, then ticks each line
// as he covers it. Each hire's ticks are kept on their plan
// (team_onboarding_plans.orientation_checked), so a later session picks up
// where the last one stopped. A line that links to a video is a video
// (asksForReply). A section is done when every line in it that is not a
// video is ticked. A section of only videos is done once one of its videos
// is ticked.
//
// When the pop-up closes, for each hire worked with:
//   - videos left unticked in a finished section go on the hire's Watch card
//     for the week (onboarding_orientation_videos); a section that is not
//     finished keeps its videos, to be done with Peter later.
//   - the Orientation line on their card is ticked when every section is
//     done, and unticked when one is still open.
// The database lets nobody but the owner tick that line
// (onboarding_step_complete_gate).
// =========================================================================

// The script cut into sections, one per heading. groups come from subGroups().
export function orientationSections(groups) {
  return groups.map(g => ({
    talk: g.items.filter(l => !asksForReply(l)),
    videos: g.items.filter(l => asksForReply(l)),
  }));
}

// Where one hire stands. checked = the lines ticked for them.
export function orientationProgress(sections, checked) {
  const has = new Set(Array.isArray(checked) ? checked : []);
  const rows = sections.map(s => {
    const talkDone = s.talk.filter(l => has.has(l)).length;
    const done = s.talk.length
      ? talkDone === s.talk.length
      : s.videos.some(l => has.has(l));
    return { done, talkDone, talkTotal: s.talk.length };
  });
  return {
    rows,
    sectionsDone: rows.filter(r => r.done).length,
    allDone: rows.length > 0 && rows.every(r => r.done),
    // Videos still to watch from sections that are done: these go on the Watch card.
    leftover: sections.flatMap((s, i) => (rows[i].done ? s.videos.filter(l => !has.has(l)) : [])),
  };
}

export default function OrientationPopup({ instruction, userId, onClose }) {
  const vp = useViewport();
  const pad = vp.isPhone ? "18px 14px" : "22px 26px";
  const todayCT = new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
  const label = instruction?.substep_label || "Orientation";
  const [body, setBody] = useState(instruction?.body_md || "");
  const [draft, setDraft] = useState(null);   // text being edited, null when not editing
  const [saving, setSaving] = useState(false);
  const [hires, setHires] = useState(null);   // null while loading
  const [here, setHere] = useState(() => new Set());   // plan ids of the hires in the room
  const [busy, setBusy] = useState(false);
  const [closing, setClosing] = useState(false);
  const [err, setErr] = useState("");
  const touched = useRef(new Set());   // plans whose ticks changed while open
  const picked = useRef(false);        // who's here gets a first guess once

  const groups = subGroups(textToSubsteps(body));
  const sections = orientationSections(groups);

  // Every new hire whose plan is running and has a card with the Orientation line.
  const load = useCallback(async () => {
    if (!supabase || !AGENCY_ID) { setHires([]); return; }
    const [plansRes, namesRes] = await Promise.all([
      supabase.from("team_onboarding_plans")
        .select("id, start_date, orientation_checked")
        .eq("agency_id", AGENCY_ID)
        .in("status", ["active", "paused"]),
      supabase.rpc("onboarding_visible_plan_names"),
    ]);
    if (plansRes.error) { setErr(plansRes.error.message); setHires([]); return; }
    const plans = new Map((plansRes.data || []).map(p => [p.id, p]));
    if (!plans.size) { setHires([]); return; }
    const { data: cards, error: cardsErr } = await supabase.from("team_onboarding_steps")
      .select("id, plan_id, substeps, substeps_done, substep_answers, completed_at")
      .in("plan_id", [...plans.keys()]);
    if (cardsErr) { setErr(cardsErr.message); setHires([]); return; }
    const names = {};
    (namesRes.data || []).forEach(r => { names[r.plan_id] = r.subject_name; });
    const byPlan = new Map();
    (cards || []).filter(c => subAll(c.substeps).includes(label)).forEach(c => {
      const p = plans.get(c.plan_id);
      if (!byPlan.has(c.plan_id)) {
        byPlan.set(c.plan_id, {
          planId: c.plan_id,
          name: names[c.plan_id] || "New hire",
          startDate: p?.start_date || null,
          checked: Array.isArray(p?.orientation_checked) ? p.orientation_checked : [],
          steps: [],
        });
      }
      byPlan.get(c.plan_id).steps.push(c);
    });
    const list = [...byPlan.values()]
      .sort((a, b) => String(a.startDate || "").localeCompare(String(b.startDate || ""))
        || a.name.localeCompare(b.name));
    setHires(list);
  }, [label]);

  useEffect(() => { load(); }, [load]);

  // First guess at who's here: everyone whose orientation isn't finished.
  useEffect(() => {
    if (picked.current || !hires) return;
    picked.current = true;
    setHere(new Set(hires.filter(h => !orientationProgress(sections, h.checked).allDone).map(h => h.planId)));
  }, [hires, sections]);

  const inRoom = (hires || []).filter(h => here.has(h.planId));

  const toggleHere = (planId) => {
    setHere(prev => {
      const next = new Set(prev);
      if (next.has(planId)) next.delete(planId); else next.add(planId);
      return next;
    });
  };

  // Tick or untick one line for everyone here. A line ticked for some of them
  // but not all is ticked for the rest.
  const toggleLine = async (line) => {
    if (!inRoom.length || busy) return;
    setErr("");
    setBusy(true);
    const allHave = inRoom.every(h => h.checked.includes(line));
    const changes = inRoom.map(h => ({
      planId: h.planId,
      next: allHave ? h.checked.filter(l => l !== line) : (h.checked.includes(line) ? h.checked : [...h.checked, line]),
    })).filter(c => c.next !== (hires.find(h => h.planId === c.planId) || {}).checked);
    const results = await Promise.all(changes.map(c =>
      supabase.from("team_onboarding_plans").update({ orientation_checked: c.next }).eq("id", c.planId)));
    setBusy(false);
    const failed = results.find(r => r.error);
    if (failed) { setErr(failed.error.message); await load(); return; }
    changes.forEach(c => touched.current.add(c.planId));
    const nextOf = new Map(changes.map(c => [c.planId, c.next]));
    setHires(prev => prev.map(h => (nextOf.has(h.planId) ? { ...h, checked: nextOf.get(h.planId) } : h)));
  };

  // On the way out: leftover videos to the Watch card, and the Orientation
  // line ticked or unticked, for each hire whose ticks changed.
  const finish = async () => {
    if (closing) return;
    if (!touched.current.size) { onClose(); return; }
    setErr("");
    setClosing(true);
    const problems = [];
    for (const h of hires || []) {
      if (!touched.current.has(h.planId)) continue;
      const prog = orientationProgress(sections, h.checked);
      const { error: vErr } = await supabase.rpc("onboarding_orientation_videos",
        { p_plan_id: h.planId, p_videos: prog.leftover });
      if (vErr) { problems.push(`${h.name}: ${vErr.message}`); continue; }
      for (const step of h.steps) {
        const ticked = Array.isArray(step.substeps_done) && step.substeps_done.includes(label);
        if (ticked === prog.allDone) continue;
        const { error: tErr } = await setSubstepDone(step, label, prog.allDone, userId);
        if (tErr) problems.push(`${h.name}: ${tErr.message}`);
      }
      touched.current.delete(h.planId);
    }
    setClosing(false);
    if (problems.length) { setErr(problems.join(" ")); await load(); return; }
    onClose();
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

  // Where the hires in the room stand, section by section.
  const progressHere = inRoom.map(h => orientationProgress(sections, h.checked));

  const sectionTag = (si) => {
    if (!inRoom.length) return null;
    const s = sections[si];
    const allDone = progressHere.every(p => p.rows[si].done);
    if (allDone) {
      return <span style={{ fontSize: 12, fontWeight: 600, color: T.green }}>Done</span>;
    }
    if (inRoom.length > 1 || !s.talk.length) return null;
    const r = progressHere[0].rows[si];
    return <span style={{ fontSize: 12, color: T.slate500 }}>{r.talkDone} of {r.talkTotal}</span>;
  };

  const errorBox = err && (
    <div style={{
      marginTop: 10, padding: "10px 12px", background: T.redLt, color: T.red,
      borderRadius: 8, fontSize: 13, boxSizing: "border-box",
    }}>{err}</div>
  );

  return (
    <PopupShell onClose={finish}>
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
        ) : (
          <>
            <Section title="Who's here"
              note="Videos left in a finished section go on their Watch card for the week. Orientation ticks itself on their card once every section is done.">
              {hires === null ? (
                <div style={{ fontSize: 13, color: T.slate500 }}>Loading…</div>
              ) : hires.length === 0 ? (
                <div style={{ fontSize: 13, color: T.slate500 }}>No new hires right now.</div>
              ) : (
                <div style={{ display: "grid", gap: 8 }}>
                  {hires.map(h => {
                    const prog = orientationProgress(sections, h.checked);
                    return (
                      <Check key={h.planId} checked={here.has(h.planId)} onChange={() => toggleHere(h.planId)}>
                        {h.name}
                        <span style={{ color: T.slate500 }}>
                          {h.startDate ? ` · ${h.startDate > todayCT ? "starts" : "started"} ${fmtDate(h.startDate)}` : ""}
                          {` · ${prog.sectionsDone} of ${sections.length} sections done`}
                        </span>
                      </Check>
                    );
                  })}
                </div>
              )}
            </Section>

            {groups.map((g, gi) => {
              return (
                <div key={gi} style={{ marginTop: gi === 0 ? 24 : 22 }}>
                  {(g.group || g.info.length > 0) && (
                    <GroupHead
                      label={g.group}
                      info={g.info}
                      extra={sectionTag(gi)}
                      style={{ marginBottom: 6 }}
                      labelStyle={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}
                      pathColor={T.teal} linkColor={T.blue}
                    />
                  )}
                  <div style={{ display: "grid", gap: 2 }}>
                    {g.items.map((line, ix) => {
                      const { level, text } = splitIndent(line);
                      const have = inRoom.filter(h => h.checked.includes(line));
                      const ticked = inRoom.length > 0 && have.length === inRoom.length;
                      const some = have.length > 0 && !ticked;
                      const off = !inRoom.length || busy;
                      return (
                        <label key={ix} style={{
                          display: "flex", gap: 10, alignItems: "flex-start", padding: "4px 0",
                          marginLeft: level * 18, cursor: off ? "default" : "pointer", minWidth: 0,
                        }}>
                          <input type="checkbox" checked={ticked} disabled={off} onChange={() => toggleLine(line)}
                            style={{ marginTop: 3, width: 16, height: 16, flexShrink: 0, accentColor: T.blue }} />
                          <div style={{ fontSize: 13.5, color: ticked ? T.slate500 : T.slate800, lineHeight: 1.5, minWidth: 0, flex: 1 }}>
                            <ItemInfo lines={g.itemInfo[line] || []} pathColor={T.teal} linkColor={T.blue}>
                              <LabelText text={text} pathColor={T.teal} linkColor={T.blue} />
                              {some && (
                                <span style={{ fontSize: 12, color: T.slate500 }}>
                                  {` · done for ${have.map(h => h.name).join(", ")}`}
                                </span>
                              )}
                            </ItemInfo>
                          </div>
                        </label>
                      );
                    })}
                  </div>
                </div>
              );
            })}
          </>
        )}

        {errorBox}

        <div style={{ marginTop: 22 }}>
          <Button variant="secondary" onClick={finish} disabled={closing}>{closing ? "Saving…" : "Done"}</Button>
        </div>
      </div>
    </PopupShell>
  );
}
