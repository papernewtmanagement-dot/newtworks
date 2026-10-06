import { useCallback, useEffect, useRef, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import {
  PopupShell, Button, GroupHead, ItemInfo, LabelText, inputBase, asksForReply,
  subGroups, subAll, splitIndent, substepsToText, textToSubsteps, wrapLongText, fmtDate, setSubstepDone,
} from "../lib/onboardingUi.jsx";
import { Section, Check } from "./TeamForms.jsx";

// A heading's checkbox: checked when every line under it is ticked, a dash
// when only some are.
function SectionBox({ checked, some, disabled, onChange }) {
  const ref = useRef(null);
  useEffect(() => { if (ref.current) ref.current.indeterminate = !!some && !checked; }, [some, checked]);
  return (
    <input ref={ref} type="checkbox" checked={!!checked} disabled={disabled} onChange={onChange}
      aria-label="Check the whole section"
      style={{ marginTop: 4, width: 17, height: 17, flexShrink: 0, accentColor: T.blue,
        cursor: disabled ? "default" : "pointer" }} />
  );
}

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
// Each heading has its own checkbox (Peter 2026-10-06). Checking it ticks
// every line under it, videos included, and folds the section. Ticking every
// line one by one checks the heading and folds it too. Unchecking it unticks
// every line and opens the section. Clicking the heading's name folds or
// opens it by hand. A section with its talking points ticked but videos left
// stays open with its heading unchecked; those videos go to the Watch card.
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
  const [fold, setFold] = useState({});   // sections folded or opened by hand: index -> folded
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

  // Every line under a heading ticked for everyone here, or only some.
  const isFull = (gi) => {
    const items = groups[gi]?.items || [];
    return inRoom.length > 0 && items.length > 0 && inRoom.every(h => items.every(l => h.checked.includes(l)));
  };
  const isSome = (gi) => {
    const items = groups[gi]?.items || [];
    return inRoom.some(h => items.some(l => h.checked.includes(l)));
  };
  const hasHead = (gi) => !!(groups[gi] && (groups[gi].group || groups[gi].info.length));
  // A section folds itself once everything in it is ticked, unless folded or
  // opened by hand since.
  const isFolded = (gi) => hasHead(gi) && (Object.prototype.hasOwnProperty.call(fold, gi) ? fold[gi] : isFull(gi));
  const toggleFold = (gi) => setFold(prev => ({ ...prev, [gi]: !isFolded(gi) }));

  // The one place ticks change: tick (on) or untick these lines for everyone here.
  const setLines = async (lines, on) => {
    if (!inRoom.length || busy || !lines.length) return;
    setErr("");
    setBusy(true);
    const changes = inRoom.map(h => {
      const next = on
        ? [...h.checked, ...lines.filter(l => !h.checked.includes(l))]
        : h.checked.filter(l => !lines.includes(l));
      return { planId: h.planId, next, same: next.length === h.checked.length };
    }).filter(c => !c.same);
    const results = await Promise.all(changes.map(c =>
      supabase.from("team_onboarding_plans").update({ orientation_checked: c.next }).eq("id", c.planId)));
    setBusy(false);
    const failed = results.find(r => r.error);
    if (failed) { setErr(failed.error.message); await load(); return; }
    changes.forEach(c => touched.current.add(c.planId));
    const nextOf = new Map(changes.map(c => [c.planId, c.next]));
    setHires(prev => prev.map(h => (nextOf.has(h.planId) ? { ...h, checked: nextOf.get(h.planId) } : h)));
    // Sections whose ticks changed go back to folding on their own.
    setFold(prev => {
      const next = { ...prev };
      groups.forEach((g, gi) => { if (g.items.some(l => lines.includes(l))) delete next[gi]; });
      return next;
    });
  };

  // One line: a line ticked for some of the hires here but not all is ticked for the rest.
  const toggleLine = (line) => setLines([line], !inRoom.every(h => h.checked.includes(line)));
  // A heading: ticks everything under it, or unticks everything when it is all ticked.
  const toggleSection = (gi) => setLines(groups[gi]?.items || [], !isFull(gi));

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

  // Talking points done but videos left: those go to the Watch card.
  const sectionTag = (gi) => {
    const sec = sections[gi];
    if (!inRoom.length || !sec?.videos.length || isFull(gi)) return null;
    if (!progressHere.every(p => p.rows[gi].done)) return null;
    const left = inRoom.length === 1 ? sec.videos.filter(l => !inRoom[0].checked.includes(l)).length : 0;
    return (
      <span style={{ fontSize: 12, fontWeight: 400, color: T.slate500 }}>
        {left === 1 ? "1 video" : left > 1 ? `${left} videos` : "Videos"} left for the Watch card
      </span>
    );
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
              const off = !inRoom.length || busy;
              const full = isFull(gi);
              const folded = isFolded(gi);
              return (
                <div key={gi} style={{ marginTop: gi === 0 ? 24 : folded ? 12 : 22 }}>
                  {hasHead(gi) && (
                    <div style={{ display: "flex", gap: 10, alignItems: "flex-start", marginBottom: folded ? 0 : 6, minWidth: 0 }}>
                      <SectionBox checked={full} some={isSome(gi)} disabled={off} onChange={() => toggleSection(gi)} />
                      <div role="button" aria-expanded={!folded} onClick={() => toggleFold(gi)}
                        style={{ display: "flex", gap: 6, alignItems: "flex-start", cursor: "pointer", minWidth: 0, flex: 1 }}>
                        <span aria-hidden="true" style={{ color: T.slate400, fontSize: 11, lineHeight: "23px", width: 10, flexShrink: 0 }}>
                          {folded ? "\u25B8" : "\u25BE"}
                        </span>
                        <GroupHead
                          label={g.group}
                          info={g.info}
                          extra={sectionTag(gi)}
                          style={{ minWidth: 0, flex: 1 }}
                          labelStyle={{ fontSize: 15, fontWeight: 700, color: full ? T.slate500 : T.slate900 }}
                          pathColor={T.teal} linkColor={T.blue}
                        />
                      </div>
                    </div>
                  )}
                  {!folded && (
                    <div style={{ display: "grid", gap: 2 }}>
                      {g.items.map((line, ix) => {
                        const { level, text } = splitIndent(line);
                        const have = inRoom.filter(h => h.checked.includes(line));
                        const ticked = inRoom.length > 0 && have.length === inRoom.length;
                        const some = have.length > 0 && !ticked;
                        return (
                          <label key={ix} style={{
                            display: "flex", gap: 10, alignItems: "flex-start", padding: "4px 0",
                            marginLeft: (hasHead(gi) ? 27 : 0) + level * 18, cursor: off ? "default" : "pointer", minWidth: 0,
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
                  )}
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
