import { useState, useEffect, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import InfoDot from "./InfoDot.jsx";
import ReplyPopup from "./ReplyPopup.jsx";
import ReferenceCalls from "../modules/ReferenceCalls.jsx";
import {
  Card, GroupHead, LabelText, ItemInfo, AfterText, InstructionsModal, FormPopupProvider,
  subGroups, splitIndent, tickingFormOf, asksForReply, setSubstepDone, setStepDone,
  wrapLongText, ORIENTATION_KIND,
} from "../lib/onboardingUi.jsx";
import { loadOngoing, developmentChanged, DEVELOPMENT_CHANGED } from "../lib/development.js";
import {
  typeLabel, humanDate, todayInCT, MarkCompleteModal, LicenseReferenceModal, markLicenseComplete,
} from "../modules/Licensing.jsx";

// =========================================================================
// OngoingCard.jsx
// =========================================================================
// The Ongoing card at the top of a person's development plan. It holds
// whatever they have due right now, from three places:
//   * a license or CE, from its first reminder email until it is marked done
//   * the handbook, while the current version is unconfirmed
//   * their part of a new hire's onboarding plan, once that card opens
// development_ongoing() decides what is on it. Each line acts on the real
// thing — the license, the handbook form, the new hire's card — so ticking
// here ticks there, and an item leaves the card the moment it is done.
// =========================================================================

export default function OngoingCard({ teamMemberId, userId, isAdmin = false, instructions = {}, icons = {}, showEmpty = false }) {
  const [items, setItems] = useState(null);       // null while the first load runs
  const [refs, setRefs] = useState({});           // license type -> how-to notes
  const [completing, setCompleting] = useState(null);
  const [refOpen, setRefOpen] = useState(null);
  const [openInstr, setOpenInstr] = useState(null);
  const [replyFor, setReplyFor] = useState(null); // {item, label}
  const [busy, setBusy] = useState(null);
  const [err, setErr] = useState("");

  const load = useCallback(async () => {
    setItems(await loadOngoing(teamMemberId));
  }, [teamMemberId]);

  useEffect(() => { load(); }, [load]);

  // Anything done elsewhere (a form, the yellow bar, another tab) refreshes it.
  useEffect(() => {
    window.addEventListener(DEVELOPMENT_CHANGED, load);
    return () => window.removeEventListener(DEVELOPMENT_CHANGED, load);
  }, [load]);

  useEffect(() => {
    let alive = true;
    if (!supabase) return () => { alive = false; };
    supabase.from("license_type_reference").select("*").eq("agency_id", AGENCY_ID)
      .then(({ data }) => {
        if (!alive) return;
        const m = {};
        (data || []).forEach(r => { m[r.license_type] = r; });
        setRefs(m);
      });
    return () => { alive = false; };
  }, []);

  // Ticking a line on a new hire's card. Same function the plan itself uses.
  const tickLine = async (item, label, answer = null) => {
    setBusy(item.key); setErr("");
    const done = Array.isArray(item.substeps_done) ? item.substeps_done : [];
    const { error } = await setSubstepDone(item, label, !done.includes(label), userId, answer);
    setBusy(null);
    if (error) { setErr(error.message); return error.message; }
    developmentChanged();
    return null;
  };

  const tickStep = async (item) => {
    setBusy(item.key); setErr("");
    const { error } = await setStepDone(item.id, true, userId);
    setBusy(null);
    if (error) { setErr(error.message); return; }
    developmentChanged();
  };

  const finishLicense = async (completedOn) => {
    setErr("");
    const { error } = await markLicenseComplete(completing.id, completedOn);
    if (error) { setErr(error.message || "Could not mark that done."); return; }
    setCompleting(null);
    developmentChanged();
  };

  if (items === null) return null;
  if (items.length === 0) {
    if (!showEmpty) return null;
    return (
      <Card style={{ marginBottom: 12 }}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>Ongoing</div>
        <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>Nothing due right now.</div>
      </Card>
    );
  }

  const today = todayInCT();

  return (
    <FormPopupProvider teamId={teamMemberId} onClosed={developmentChanged}>
      <Card style={{ marginBottom: 12, border: `1px solid ${T.amber}` }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, marginBottom: 12 }}>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>Ongoing</div>
          <div style={{ fontSize: 11, color: T.slate500 }}>{items.length}</div>
        </div>
        {err && <div style={{ fontSize: 12, color: T.red, marginBottom: 10 }}>{err}</div>}
        <div style={{
          display: "grid", gap: 12, alignItems: "start",
          gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))",
        }}>
          {items.map(item => (
            <Box key={item.key} item={item} today={today}>
              {item.kind === "license" && (
                <Line
                  text={item.hours_required ? `Mark done (${item.hours_required} hours)` : "Mark done"}
                  onTick={() => setCompleting(item)}
                  after={refs[item.license_type] && (
                    <AfterText><InfoDot title="How to do it" onClick={() => setRefOpen(refs[item.license_type])} /></AfterText>
                  )}
                />
              )}

              {item.kind === "handbook" && (
                <Line text={item.line} title="Ticks itself when the form is done" />
              )}

              {item.kind === "onboarding" && (
                <OnboardingItem
                  item={item}
                  busy={busy === item.key}
                  instructions={instructions}
                  icons={icons}
                  onTickLine={(label) => tickLine(item, label)}
                  onReply={(label) => setReplyFor({ item, label })}
                  onTickStep={() => tickStep(item)}
                  onInstr={setOpenInstr}
                />
              )}
            </Box>
          ))}
        </div>
      </Card>

      {completing && (
        <MarkCompleteModal
          row={{
            license_type: completing.license_type, states: completing.states,
            due_date: completing.due, cycle_months: completing.cycle_months,
          }}
          member={null}
          onClose={() => setCompleting(null)}
          onConfirm={finishLicense}
        />
      )}
      {refOpen && <LicenseReferenceModal reference={refOpen} onClose={() => setRefOpen(null)} />}
      <InstructionsModal item={openInstr} onClose={() => setOpenInstr(null)} canEdit={isAdmin} />
      {replyFor && (
        <ReplyPopup
          label={replyFor.label}
          onClose={() => setReplyFor(null)}
          onSave={async (text) => {
            const e = await tickLine(replyFor.item, replyFor.label, text);
            if (!e) setReplyFor(null);
            return e;
          }}
        />
      )}
    </FormPopupProvider>
  );
}

// One item on the card: its name, who it is for, and when it is due.
function Box({ item, today, children }) {
  const title = item.kind === "license" ? typeLabel(item.license_type) : item.title;
  const states = item.kind === "license" && Array.isArray(item.states) && item.states.length
    ? ` (${item.states.join(", ")})` : "";
  const late = item.due && item.due < today;
  return (
    <div style={{
      border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "10px 12px",
      boxSizing: "border-box", background: T.white, minWidth: 0, ...wrapLongText,
    }}>
      <div style={{ fontSize: 13, fontWeight: 600, color: T.slate900, lineHeight: 1.4 }}>
        {title}{states}
      </div>
      <div style={{ fontSize: 11, color: late ? T.red : T.slate500, marginTop: 2, fontWeight: late ? 600 : 400 }}>
        {item.kind === "onboarding" && item.subject ? `For ${item.subject}` : ""}
        {item.kind === "onboarding" && item.subject && item.due ? " · " : ""}
        {item.due ? `${late ? "Was due" : "Due"} ${humanDate(item.due)}` : ""}
        {item.kind === "handbook" && item.updated ? " · new version" : ""}
      </div>
      <div style={{ marginTop: 8 }}>{children}</div>
    </div>
  );
}

// A checklist line. No onTick = it ticks itself from somewhere else.
function Line({ text, done = false, onTick, title, after = null, icon = null, level = 0, children = null }) {
  return (
    <div
      onClick={onTick}
      title={title}
      style={{
        display: "flex", gap: 7, alignItems: "flex-start", minWidth: 0,
        marginLeft: level * 18, cursor: onTick ? "pointer" : "default",
      }}
    >
      <button
        type="button"
        aria-label={typeof text === "string" ? text : undefined}
        aria-pressed={done}
        style={{
          width: 14, height: 14, borderRadius: 3, flexShrink: 0,
          margin: "2px 0 0", padding: 0, boxSizing: "border-box",
          appearance: "none", WebkitAppearance: "none", cursor: "inherit",
          background: done ? T.green : T.white,
          border: `1.5px solid ${done ? T.green : T.slate300}`,
          display: "flex", alignItems: "center", justifyContent: "center",
        }}
      >
        {done && <span style={{ color: T.white, fontSize: 9, lineHeight: 1 }}>✓</span>}
      </button>
      <div style={{ flex: 1, minWidth: 0, fontSize: 12, lineHeight: 1.4 }}>
        <span style={{ color: done ? T.slate400 : T.slate700, textDecoration: done ? "line-through" : "none" }}>
          <LabelText text={text} icon={icon} pathColor={done ? T.slate400 : T.teal} linkColor={T.blue} />
        </span>
        {after}
        {children}
      </div>
    </div>
  );
}

// Someone's part of a new hire's card.
function OnboardingItem({ item, busy, instructions, icons, onTickLine, onReply, onTickStep, onInstr }) {
  const groups = subGroups(item.substeps).filter(g => !g.altFor);
  const done = Array.isArray(item.substeps_done) ? item.substeps_done : [];
  const head = (g) => (g.group || g.info.length > 0) && (
    <GroupHead
      label={g.group}
      info={g.info}
      style={{ marginBottom: 4 }}
      labelStyle={{ fontSize: 10, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: 0.4 }}
      pathColor={T.teal} linkColor={T.blue}
    />
  );

  const description = item.description && (
    <div style={{ fontSize: 11, color: T.slate500, marginBottom: 6, lineHeight: 1.45 }}>
      <LabelText text={item.description} pathColor={T.teal} linkColor={T.blue} />
    </div>
  );

  // The references card carries the calling list itself.
  if (item.auto_source === "references") {
    return <>{description}<ReferenceCalls candidateId={item.candidate_id} embedded /></>;
  }

  // A card the whole team works: each person ticks their own name. Their name
  // can sit under more than one heading and is one tick for all of them.
  if (Array.isArray(item.mine)) {
    return (
      <div style={{ opacity: busy ? 0.6 : 1 }}>
        {description}
        {item.mine.map(key => (
          <div key={key} style={{ marginBottom: 6 }}>
            {groups.filter(g => g.keys.includes(key)).map((g, gi) => <div key={gi}>{head(g)}</div>)}
            <Line text="Done" onTick={busy ? undefined : () => onTickLine(key)} />
          </div>
        ))}
      </div>
    );
  }

  // A card with no lines is ticked as a whole.
  if (groups.length === 0) {
    return (
      <div style={{ opacity: busy ? 0.6 : 1 }}>
        {description}
        <Line text="Done" onTick={busy ? undefined : onTickStep} />
      </div>
    );
  }

  return (
    <div style={{ opacity: busy ? 0.6 : 1 }}>
      {description}
      {groups.map((g, gi) => (
        <div key={gi} style={{ marginTop: gi === 0 ? 0 : 10 }}>
          {head(g)}
          <div style={{ display: "grid", gap: 5 }}>
            {g.items.map((label, ix) => {
              const key = g.keys[ix];
              const sd = done.includes(key);
              const byForm = !!tickingFormOf(label);
              const { level, text: shown } = splitIndent(label);
              const instr = instructions[shown];
              const locked = instr?.kind === ORIENTATION_KIND;
              const wantsReply = asksForReply(label);
              const reply = wantsReply && sd ? (item.substep_answers || {})[key] : null;
              const onTick = busy || byForm || locked ? undefined
                : (wantsReply && !sd) ? () => onReply(key)
                : () => onTickLine(key);
              return (
                <ItemInfo key={ix} lines={g.itemInfo[label] || []} pathColor={T.teal} linkColor={T.blue}>
                  {(howTo) => (
                    <Line
                      text={shown} done={sd} level={level} icon={icons[shown] || null}
                      onTick={onTick}
                      title={byForm ? "Ticks itself when the form is done" : undefined}
                      after={<>
                        {instr && !locked && (
                          <AfterText><InfoDot title="Instructions" onClick={(e) => { e?.stopPropagation?.(); onInstr(instr); }} /></AfterText>
                        )}
                        {howTo}
                      </>}
                    >
                      {reply && (
                        <div style={{ marginTop: 2, color: T.slate700, fontStyle: "italic", whiteSpace: "pre-wrap" }}>{reply}</div>
                      )}
                    </Line>
                  )}
                </ItemInfo>
              );
            })}
          </div>
        </div>
      ))}
    </div>
  );
}
