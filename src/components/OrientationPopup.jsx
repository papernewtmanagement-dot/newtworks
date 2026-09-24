import { useCallback, useEffect, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import {
  PopupShell, Button, GroupHead, ItemInfo, LabelText,
  subGroups, splitIndent, wrapLongText, fmtDate, setStepDone, ORIENTATION_WIDGET,
} from "../lib/onboardingUi.jsx";
import { Section, Check } from "./TeamForms.jsx";

// =========================================================================
// OrientationPopup.jsx
// =========================================================================
// Peter's orientation, opened from the (i) on the Orientation card. Only the
// owner sees that (i). The card's sub-items are his talking points, shown
// here in order, laid out like the Onboarding form. At the bottom there is
// one checkmark per new hire: checking one checks off Orientation on that
// hire's plan, and unchecking undoes it. The database lets nobody but the
// owner check that card off (onboarding_step_complete_gate).
// =========================================================================

export default function OrientationPopup({ title, substeps, userId, onClose }) {
  const vp = useViewport();
  const pad = vp.isPhone ? "18px 14px" : "22px 26px";
  const todayCT = new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
  const [hires, setHires] = useState(null); // null while loading
  const [busy, setBusy] = useState(null);   // the card being saved
  const [err, setErr] = useState("");

  // Every new hire whose plan is running and has the Orientation card.
  const load = useCallback(async () => {
    if (!supabase || !AGENCY_ID) { setHires([]); return; }
    const { data: cards, error: cardsErr } = await supabase.from("team_onboarding_steps")
      .select("id, plan_id, completed_at, unlocks_on")
      .eq("widget", ORIENTATION_WIDGET);
    if (cardsErr) { setErr(cardsErr.message); setHires([]); return; }
    const planIds = [...new Set((cards || []).map(c => c.plan_id))];
    if (!planIds.length) { setHires([]); return; }
    const [plansRes, namesRes] = await Promise.all([
      supabase.from("team_onboarding_plans")
        .select("id, status, start_date")
        .eq("agency_id", AGENCY_ID)
        .in("id", planIds)
        .in("status", ["active", "paused"]),
      supabase.rpc("onboarding_visible_plan_names"),
    ]);
    if (plansRes.error) { setErr(plansRes.error.message); setHires([]); return; }
    const names = {};
    (namesRes.data || []).forEach(r => { names[r.plan_id] = r.subject_name; });
    const plans = new Map((plansRes.data || []).map(p => [p.id, p]));
    const list = (cards || [])
      .filter(c => plans.has(c.plan_id))
      .map(c => ({
        stepId: c.id,
        name: names[c.plan_id] || "New hire",
        startDate: plans.get(c.plan_id).start_date || null,
        completedAt: c.completed_at,
        unlocksOn: c.unlocks_on,
      }))
      .sort((a, b) => String(a.startDate || "").localeCompare(String(b.startDate || ""))
        || a.name.localeCompare(b.name));
    setHires(list);
  }, []);

  useEffect(() => { load(); }, [load]);

  const toggle = async (h) => {
    setErr("");
    setBusy(h.stepId);
    const { error } = await setStepDone(h.stepId, !h.completedAt, userId);
    setBusy(null);
    if (error) { setErr(error.message); return; }
    await load();
  };

  const groups = subGroups(substeps);

  return (
    <PopupShell onClose={onClose}>
      <div style={{ padding: pad, minWidth: 0, ...wrapLongText }}>
        <div style={{ fontSize: 19, fontWeight: 700, color: T.slate900, letterSpacing: "-0.01em", paddingRight: 30 }}>
          {title || "Orientation"}
        </div>

        {groups.map((g, gi) => (
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
              {g.items.map((label, ix) => {
                const { level, text } = splitIndent(label);
                return (
                  <li key={ix} style={{ fontSize: 13.5, color: T.slate800, lineHeight: 1.5, marginLeft: level * 18 }}>
                    <ItemInfo lines={g.itemInfo[label] || []} pathColor={T.teal} linkColor={T.blue}>
                      <LabelText text={text} pathColor={T.teal} linkColor={T.blue} />
                    </ItemInfo>
                  </li>
                );
              })}
            </ul>
          </div>
        ))}

        <Section title="Who was there" note="Checking someone off checks off Orientation on their plan.">
          {hires === null ? (
            <div style={{ fontSize: 13, color: T.slate500 }}>Loading…</div>
          ) : hires.length === 0 ? (
            <div style={{ fontSize: 13, color: T.slate500 }}>No new hires right now.</div>
          ) : (
            <div style={{ display: "grid", gap: 8 }}>
              {hires.map(h => {
                const notYet = !h.completedAt && !!h.unlocksOn && h.unlocksOn > todayCT;
                const when = notYet
                  ? ` · opens ${fmtDate(h.unlocksOn)}`
                  : h.startDate
                    ? ` · ${h.startDate > todayCT ? "starts" : "started"} ${fmtDate(h.startDate)}`
                    : "";
                return (
                  <Check key={h.stepId} checked={!!h.completedAt}
                    disabled={notYet || busy === h.stepId}
                    onChange={() => toggle(h)}>
                    {h.name}<span style={{ color: T.slate500 }}>{when}</span>
                  </Check>
                );
              })}
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
