import { useCallback, useEffect, useRef, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink, handleModuleLinkClick } from "../lib/routing.jsx";
import { mdToHtml } from "../lib/markdown.js";
import { ManualBodyStyles } from "../lib/manualBodyStyles.jsx";

// =========================================================================
// Roleplaying.jsx — the family game module (below Inventory; hub login + admins).
// Build plan: persistent_memory spec "Roleplaying module — build plan" (project roleplaying).
// Step 2: Characters tab — roll a character, the interactive sheet, rolls, items and coins.
// Step 3: Creatures tab — creature cards (Bramblemaw first). Parents see the whole card and
// the character-scale numbers the table uses (attack, defense, vitality ... set by the game
// master; the d20 stat block is kept as reading and flavor); players see a creature's names,
// haunts and lore once a parent taps Show to players.
// Step 4: Rules tab — the manual text verbatim (rpg_rules), every formula spelled out the
// same way the sheet does it, a needed-roll calculator, and the level-cost table.
// Step 5: Play tab, fights without a map. The game master sets up a fight, everyone takes turns by
// Agility, players attack and roll checks on their character's turn, the game master rolls the
// creatures' card actions, and every screen follows along live. Maps land in step 6.
// Every number comes from the database, one saved function per job:
//   rpg_character_list()                     the character cards
//   rpg_sheet(id, difficulty)                every stat, what a roll needs at that difficulty
//   rpg_new_character(name, kid, is_npc)     rolls the strengths on the server
//   rpg_reroll_character(id)                 fresh strengths (household: only before the first roll)
//   rpg_set_input(id, key, value)            parents set a rolled stat by hand ("special means")
//   rpg_roll(id, stat, difficulty, label)    one d100 roll: result, skill points, level-ups
//   rpg_roll_extra(roll_id)                  the additional roll a critical prompts (can chain)
//   rpg_adjust_vitality(id, delta)           damage taken (+) or healed (−)
//   rpg_recent_rolls(id)                     the roll log
//   rpg_creature_list()                      the creature cards (players: shown ones only)
//   rpg_creature_card(id)                    one card; players get names, haunts and lore only
//   rpg_rules_page()                         the Rules tab in one read: rules, formulas, level costs
//   rpg_needed(skill, difficulty)            what a roll needs; the calculator asks the same function a roll does
//   rpg_difficulty(skill, can_act)           the difficulty a defender presents: their skill × 2 when they can act (skill and will)
//   rpg_session_list() / rpg_session_state(id)   the fights, and one fight in one read (players: creatures without numbers)
//   rpg_session_new / rpg_session_add      set up a fight; Agility places each one in the turn order (no manual moves)
//   rpg_session_next_turn(id)                starts the fight or passes the turn: effects clear by rule, turn counts go up
//                                            (cooldowns are in turns), other creatures roll a die for a legendary action
//   rpg_act(actor, targets, stat, action, against, difficulty, roll, effect)   one move through rpg_roll: an attack, a
//                                            card action, or the check a rule demands; effects land by the card's rules
//   rpg_act_extra(roll, die)                 the extra die a hand-rolled critical asked for
//   rpg_session_auto_turn(id)                the site plays a creature's turn: best ready move by rpg_action_score, then passes
//   rpg_creatures.image_path                 a picture in the private rpg-images bucket (parents upload)
//   rpg_session_set_status / rpg_session_adjust_vitality / rpg_session_remove / rpg_session_end   game master changes
// Items and coins are plain rows the household edits directly (rpg_items, rpg_characters).
// Show to players is a plain update on rpg_creatures (parents only, by row rules).
// =========================================================================

const PARENT_ROLES = ["owner", "admin"];
const TABS = ["characters", "creatures", "rules", "play"];
const TAB_LABELS = { characters: "Characters", creatures: "Creatures", rules: "Rules", play: "Play" };
const GROUPS = [
  ["strength", "Strengths"],
  ["physical", "Physical Attributes"],
  ["spiritual", "Spiritual Attributes"],
  ["ability", "Character Abilities"],
  ["fighting", "Fighting"],
];
const COINS = [["platinum", "Platinum"], ["gold", "Gold"], ["silver", "Silver"], ["copper", "Copper"]];

const card = { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: 14, boxSizing: "border-box" };
const input = { border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "7px 9px", fontSize: 13, fontFamily: "inherit", boxSizing: "border-box", background: T.white, color: T.slate900 };
const btn = (kind = "soft", small = false) => ({
  border: `1px solid ${kind === "primary" ? T.blue : kind === "danger" ? T.red : T.slate200}`,
  background: kind === "primary" ? T.blue : T.white,
  color: kind === "primary" ? T.white : kind === "danger" ? T.red : T.slate700,
  borderRadius: 8, padding: small ? "4px 8px" : "7px 12px", fontSize: small ? 12 : 13, fontWeight: 600,
  cursor: "pointer", fontFamily: "inherit", whiteSpace: "nowrap", boxSizing: "border-box",
});
const label = { fontSize: 11, fontWeight: 700, color: T.slate500, letterSpacing: "0.05em", textTransform: "uppercase" };

const num = (n, d = 0) => { const v = Number(n); return Number.isFinite(v) ? v.toFixed(d) : "—"; };
const needsText = (s) => `needs ${Math.ceil(Number(s?.needed) || 0)}+ · crit ${Math.ceil(Number(s?.critical) || 0)}+`;
const resultText = (r) => (r === "C" ? "Critical!" : r === "Y" ? "Success" : "Fail");
const resultColor = (r) => (r === "C" ? T.gold : r === "Y" ? T.green : T.red);
const when = (iso) => { try { return new Date(iso).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: "America/Chicago" }); } catch (_) { return ""; } };

export default function Roleplaying({ userRole }) {
  const isParent = PARENT_ROLES.includes(userRole);
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const [tab, setTab, tabHref] = useTabParam("tab", "characters", TABS);
  const [characterId, setCharacterId, characterHref] = useTabParam("character", null);
  const [creatureId, setCreatureId, creatureHref] = useTabParam("creature", null);
  const [fightId, setFightId, fightHref] = useTabParam("fight", null);
  const [kids, setKids] = useState([]);
  const [defs, setDefs] = useState([]);
  const [err, setErr] = useState(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [k, d] = await Promise.all([
        supabase.from("family_kids").select("id,name,sort_order").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("rpg_stat_definitions").select("key,name,abbr,grp,kind,trainable,sort_order").eq("agency_id", AGENCY_ID).order("sort_order"),
      ]);
      if (!alive) return;
      if (k.error) setErr(k.error.message);
      if (d.error) setErr(d.error.message);
      setKids(Array.isArray(k.data) ? k.data : []);
      setDefs(Array.isArray(d.data) ? d.data : []);
    })();
    return () => { alive = false; };
  }, []);

  const activeTab = TABS.includes(tab) ? tab : "characters";

  return (
    <div style={{ padding: _pad, maxWidth: 980, margin: "0 auto", boxSizing: "border-box" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 10, marginBottom: 12 }}>
        <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900 }}>Roleplaying</div>
        {TABS.length > 1 && (
          <div style={{ display: "flex", gap: 6, overflowX: "auto", whiteSpace: "nowrap" }}>
            {TABS.map(t => (
              <TabLink key={t} href={tabHref(t)} onSelect={() => setTab(t)}
                style={{ ...btn(activeTab === t ? "primary" : "soft", true), flexShrink: 0 }}>{TAB_LABELS[t]}</TabLink>
            ))}
          </div>
        )}
      </div>
      {err && <div style={{ ...card, borderColor: T.red, color: T.red, marginBottom: 12, fontSize: 13 }}>{err}</div>}
      {activeTab === "characters" && (
        characterId
          ? <CharacterSheet id={characterId} isParent={isParent} kids={kids} defs={defs} isPhone={_vp.isPhone}
              onBack={() => setCharacterId(null)} backHref={characterHref(null)} onError={setErr} />
          : <CharacterList isParent={isParent} kids={kids} onOpen={setCharacterId} hrefFor={characterHref} onError={setErr} />
      )}
      {activeTab === "creatures" && (
        creatureId
          ? <CreatureCard id={creatureId} onBack={() => setCreatureId(null)} backHref={creatureHref(null)} onError={setErr} />
          : <CreatureList isParent={isParent} onOpen={setCreatureId} hrefFor={creatureHref} onError={setErr} />
      )}
      {activeTab === "rules" && <RulesTab onError={setErr} />}
      {activeTab === "play" && (fightId
        ? <FightView id={fightId} isParent={isParent} defs={defs} onBack={() => setFightId(null)} backHref={fightHref(null)} onError={setErr} />
        : <FightList isParent={isParent} onOpen={setFightId} hrefFor={fightHref} onError={setErr} />)}
    </div>
  );
}

// ── Characters list + "New character" ───────────────────────────────────────
function CharacterList({ isParent, kids, onOpen, hrefFor, onError }) {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState("");
  const [kidId, setKidId] = useState("");
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("rpg_character_list");
    if (error) onError(error.message);
    setRows(Array.isArray(data) ? data : []);
    setLoading(false);
  }, [onError]);
  useEffect(() => { load(); }, [load]);

  const create = async () => {
    if (!name.trim() || busy) return;
    setBusy(true);
    const { data, error } = await supabase.rpc("rpg_new_character", { p_name: name.trim(), p_kid_id: kidId && kidId !== "npc" ? kidId : null, p_is_npc: kidId === "npc" });
    setBusy(false);
    if (error) { onError(error.message); return; }
    setName(""); setKidId(""); setAdding(false);
    if (data) onOpen(data);
  };

  if (loading) return <div style={{ color: T.slate500, fontSize: 13 }}>Loading</div>;

  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 10, marginBottom: 10 }}>
        <div style={label}>Characters</div>
        <button type="button" style={btn(adding ? "soft" : "primary")} onClick={() => setAdding(a => !a)}>{adding ? "Cancel" : "New character"}</button>
      </div>
      {adding && (
        <div style={{ ...card, marginBottom: 12 }}>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: 8 }}>
            <input style={input} placeholder="Character name" value={name} onChange={e => setName(e.target.value)} autoFocus
              onKeyDown={e => { if (e.key === "Enter") create(); }} />
            <select style={input} value={kidId} onChange={e => setKidId(e.target.value)}>
              <option value="">Who plays it?</option>
              {(kids || []).map(k => <option key={k.id} value={k.id}>{k.name}</option>)}
              <option value="npc">Nobody — an NPC</option>
            </select>
            <button type="button" style={btn("primary")} disabled={busy || !name.trim()} onClick={create}>{busy ? "Rolling…" : "Roll the strengths"}</button>
          </div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 8 }}>Each strength rolls a d100 ÷ 10, rounded up. The sheet calculates everything else.</div>
        </div>
      )}
      {rows.length === 0 && !adding && <div style={{ ...card, color: T.slate500, fontSize: 13 }}>No characters yet. Tap New character to roll one.</div>}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 10 }}>
        {rows.map(r => (
          <TabLink key={r.id} href={hrefFor(r.id)} onSelect={() => onOpen(r.id)}
            style={{ ...card, display: "flex", alignItems: "center", gap: 12, textDecoration: "none", color: "inherit", cursor: "pointer" }}>
            <div style={{ width: 40, height: 40, borderRadius: "50%", background: r.color || T.blue, color: T.white, display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 700, fontSize: 16, flexShrink: 0, boxSizing: "border-box" }}>
              {String(r.name || "?").slice(0, 1).toUpperCase()}
            </div>
            <div style={{ minWidth: 0 }}>
              <div style={{ fontWeight: 700, color: T.slate900, fontSize: 14, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{r.name}</div>
              <div style={{ fontSize: 12, color: T.slate500 }}>{r.is_npc ? "NPC" : (r.kid_name ? `Played by ${r.kid_name}` : "No player yet")}{Number(r.vitality_damage) > 0 ? ` · hurt ${r.vitality_damage}` : ""}</div>
            </div>
          </TabLink>
        ))}
      </div>
      {isParent && rows.length > 0 && <div style={{ fontSize: 12, color: T.slate500, marginTop: 10 }}>Open a character to set strengths by hand, re-roll, or remove it.</div>}
    </div>
  );
}

// ── The character sheet ──────────────────────────────────────────────────────
function CharacterSheet({ id, isParent, kids, defs, isPhone, onBack, backHref, onError }) {
  const [sheet, setSheet] = useState(null);
  const [rolls, setRolls] = useState([]);
  const [difficulty, setDifficulty] = useState(null);   // null until the sheet's default arrives; "" while the box is being retyped
  const [missing, setMissing] = useState(false);
  const [chain, setChain] = useState([]);                // the roll on screen plus its extra rolls
  const [rolling, setRolling] = useState(null);          // stat key being rolled
  const [editing, setEditing] = useState(false);
  const [form, setForm] = useState({});
  const [coins, setCoins] = useState(null);
  const [hurt, setHurt] = useState("1");
  const [item, setItem] = useState({ name: "", stat_key: "", bonus: "1", uses_left: "" });
  const [openGroups, setOpenGroups] = useState(() => Object.fromEntries(GROUPS.map(([g]) => [g, true])));
  const [busy, setBusy] = useState(false);
  const debounce = useRef(null);

  const load = useCallback(async (diff) => {
    const [s, r] = await Promise.all([
      supabase.rpc("rpg_sheet", { p_character_id: id, p_difficulty: diff ?? null }),
      supabase.rpc("rpg_recent_rolls", { p_character_id: id, p_limit: 20 }),
    ]);
    if (s.error) { onError(s.error.message); setMissing(true); return; }
    if (r.error) onError(r.error.message);
    setSheet(s.data || null);
    setRolls(Array.isArray(r.data) ? r.data : []);
    if (diff == null && s.data) setDifficulty(Number(s.data.difficulty));
    if (s.data && coins == null) setCoins({ ...(s.data.coins || {}) });
  }, [id, onError, coins]);
  useEffect(() => { load(null); }, [id]); // eslint-disable-line react-hooks/exhaustive-deps

  // Changing the difficulty re-reads the sheet so Needed and Critical update on every stat (one call, not 60).
  const effDiff = (difficulty === "" || difficulty == null) ? null : Math.max(0, Number(difficulty) || 0);
  const changeDifficulty = (v) => {
    if (v === "") { setDifficulty(""); return; }   // box being retyped: keep the last sheet until a number lands
    const d = Math.max(0, Number(v) || 0);
    setDifficulty(d);
    if (debounce.current) clearTimeout(debounce.current);
    debounce.current = setTimeout(() => load(d), 250);
  };

  const roll = async (stat) => {
    if (rolling) return;
    setRolling(stat.key);
    const { data, error } = await supabase.rpc("rpg_roll", { p_character_id: id, p_stat_key: stat.key, p_difficulty: effDiff, p_label: stat.name });
    setRolling(null);
    if (error) { onError(error.message); return; }
    setChain([data]);
    load(effDiff);
  };
  const rollExtra = async () => {
    const last = chain[chain.length - 1];
    if (!last || !last.extra_pending || rolling) return;
    setRolling(last.stat_key);
    const { data, error } = await supabase.rpc("rpg_roll_extra", { p_parent_roll_id: last.roll_id });
    setRolling(null);
    if (error) { onError(error.message); return; }
    setChain(c => [...c, data]);
    load(effDiff);
  };

  const adjustVitality = async (sign) => {
    const amt = Math.max(0, Math.round(Number(hurt) || 0));
    if (!amt || busy) return;
    setBusy(true);
    const { error } = await supabase.rpc("rpg_adjust_vitality", { p_character_id: id, p_delta: sign * amt });
    setBusy(false);
    if (error) onError(error.message);
    load(effDiff);
  };

  const saveCoins = async () => {
    if (!coins || busy) return;
    setBusy(true);
    const patch = Object.fromEntries(COINS.map(([k]) => [k, Math.max(0, Math.round(Number(coins[k]) || 0))]));
    const { error } = await supabase.from("rpg_characters").update(patch).eq("id", id);
    setBusy(false);
    if (error) onError(error.message);
    load(effDiff);
  };

  const startEdit = () => {
    setForm({ name: sheet?.name || "", kid_id: sheet?.is_npc ? "npc" : (sheet?.kid_id || ""), color: sheet?.color || T.blue, notes: sheet?.notes || "" });
    setEditing(true);
  };
  const saveEdit = async () => {
    if (!form.name?.trim() || busy) return;
    setBusy(true);
    const { error } = await supabase.from("rpg_characters").update({
      name: form.name.trim(), kid_id: form.kid_id && form.kid_id !== "npc" ? form.kid_id : null,
      is_npc: form.kid_id === "npc", color: form.color || T.blue, notes: form.notes || null,
    }).eq("id", id);
    setBusy(false);
    if (error) onError(error.message);
    setEditing(false);
    load(effDiff);
  };

  const addItem = async () => {
    if (!item.name.trim() || busy) return;
    setBusy(true);
    const { error } = await supabase.from("rpg_items").insert({
      agency_id: AGENCY_ID, character_id: id, name: item.name.trim(), stat_key: item.stat_key || null,
      bonus: Math.round(Number(item.bonus) || 0), uses_left: item.uses_left === "" ? null : Math.max(0, Math.round(Number(item.uses_left) || 0)),
      sort_order: (sheet?.items || []).length + 1,
    });
    setBusy(false);
    if (error) onError(error.message);
    setItem({ name: "", stat_key: "", bonus: "1", uses_left: "" });
    load(effDiff);
  };
  const toggleItem = async (it) => {
    const { error } = await supabase.from("rpg_items").update({ equipped: !it.equipped }).eq("id", it.id);
    if (error) onError(error.message);
    load(effDiff);
  };
  const useItem = async (it) => {
    if (it.uses_left == null || it.uses_left <= 0) return;
    const { error } = await supabase.from("rpg_items").update({ uses_left: it.uses_left - 1 }).eq("id", it.id);
    if (error) onError(error.message);
    load(effDiff);
  };
  const deleteItem = async (it) => {
    if (!window.confirm(`Delete ${it.name}?`)) return;
    const { error } = await supabase.from("rpg_items").delete().eq("id", it.id);
    if (error) onError(error.message);
    load(effDiff);
  };

  const setInput = async (stat) => {
    const v = window.prompt(`${stat.name}: set the rolled value (now ${stat.base})`, String(stat.base));
    if (v == null || v === "") return;
    const { error } = await supabase.rpc("rpg_set_input", { p_character_id: id, p_key: stat.key, p_value: Math.round(Number(v) || 0) });
    if (error) onError(error.message);
    load(effDiff);
  };
  const reroll = async () => {
    if (!window.confirm("Roll a fresh set of strengths for this character?")) return;
    const { error } = await supabase.rpc("rpg_reroll_character", { p_character_id: id });
    if (error) onError(error.message);
    setChain([]);
    load(effDiff);
  };
  const remove = async () => {
    if (!window.confirm(`Delete ${sheet?.name} for good? Items and rolls go with it.`)) return;
    const { error } = await supabase.from("rpg_characters").delete().eq("id", id);
    if (error) { onError(error.message); return; }
    onBack();
  };

  if (missing) return <div style={{ ...card, fontSize: 13, color: T.slate700 }}>That character is gone. <a href={backHref} onClick={(e) => { if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return; e.preventDefault(); onBack(); }} style={{ color: T.blue }}>Back to characters</a></div>;
  if (!sheet) return <div style={{ color: T.slate500, fontSize: 13 }}>Loading</div>;

  const stats = Array.isArray(sheet.stats) ? sheet.stats : [];
  const unplayed = rolls.length === 0;
  const canReroll = isParent || unplayed;
  const last = chain[chain.length - 1];
  const chainTotal = chain.reduce((s, r) => s + (Number(r.roll) || 0), 0);
  const vitMax = Number(sheet.vitality_max) || 0;
  const vitLeft = Number(sheet.vitality_left) || 0;
  const vitPct = vitMax > 0 ? Math.max(0, Math.min(100, (vitLeft / vitMax) * 100)) : 0;

  return (
    <div>
      <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap", marginBottom: 10 }}>
        <a href={backHref} onClick={(e) => { if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return; e.preventDefault(); onBack(); }}
          style={{ ...btn("soft", true), textDecoration: "none", display: "inline-block" }}>← Characters</a>
        <div style={{ width: 34, height: 34, borderRadius: "50%", background: sheet.color || T.blue, color: T.white, display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 700, boxSizing: "border-box" }}>
          {String(sheet.name || "?").slice(0, 1).toUpperCase()}
        </div>
        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={{ fontSize: 18, fontWeight: 700, color: T.slate900 }}>{sheet.name}</div>
          <div style={{ fontSize: 12, color: T.slate500 }}>{sheet.is_npc ? "NPC" : (sheet.kid_name ? `Played by ${sheet.kid_name}` : "No player yet")}</div>
        </div>
        <button type="button" style={btn("soft", true)} onClick={editing ? () => setEditing(false) : startEdit}>{editing ? "Cancel" : "Edit"}</button>
        {canReroll && <button type="button" style={btn("soft", true)} onClick={reroll} title={unplayed ? "Roll a fresh set of strengths" : "Parents can re-roll any time"}>Re-roll strengths</button>}
      </div>

      {editing && (
        <div style={{ ...card, marginBottom: 12 }}>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: 8 }}>
            <input style={input} value={form.name} placeholder="Name" onChange={e => setForm(f => ({ ...f, name: e.target.value }))} />
            <select style={input} value={form.kid_id} onChange={e => setForm(f => ({ ...f, kid_id: e.target.value }))}>
              <option value="">No player yet</option>
              {(kids || []).map(k => <option key={k.id} value={k.id}>{k.name}</option>)}
              <option value="npc">Nobody — an NPC</option>
            </select>
            <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: T.slate700 }}>
              Color <input type="color" value={form.color} onChange={e => setForm(f => ({ ...f, color: e.target.value }))} style={{ width: 44, height: 30, border: "none", background: "none", cursor: "pointer" }} />
            </label>
          </div>
          <textarea style={{ ...input, width: "100%", minHeight: 60, marginTop: 8 }} placeholder="Notes (looks, story, anything)" value={form.notes} onChange={e => setForm(f => ({ ...f, notes: e.target.value }))} />
          <div style={{ display: "flex", gap: 8, marginTop: 8, flexWrap: "wrap" }}>
            <button type="button" style={btn("primary")} disabled={busy} onClick={saveEdit}>Save</button>
            {isParent && <button type="button" style={btn("danger")} onClick={remove}>Delete character</button>}
          </div>
        </div>
      )}

      {/* Vitality + difficulty: the two numbers every roll needs, side by side */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(260px, 1fr))", gap: 10, marginBottom: 12 }}>
        <div style={card}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", flexWrap: "wrap", gap: 6 }}>
            <div style={label}>Physical Vitality</div>
            <div style={{ fontSize: 14, fontWeight: 700, color: vitLeft === 0 ? T.red : T.slate900 }}>{vitLeft} / {vitMax}{vitLeft === 0 ? " · down" : ""}</div>
          </div>
          <div style={{ height: 8, background: T.slate100, borderRadius: 4, marginTop: 8, overflow: "hidden" }}>
            <div style={{ width: `${vitPct}%`, height: "100%", background: vitPct > 50 ? T.green : vitPct > 25 ? T.amber : T.red, transition: "width .3s" }} />
          </div>
          <div style={{ display: "flex", gap: 6, marginTop: 10, alignItems: "center", flexWrap: "wrap" }}>
            <input style={{ ...input, width: 64 }} inputMode="numeric" value={hurt} onChange={e => setHurt(e.target.value)} />
            <button type="button" style={btn("danger", true)} disabled={busy} onClick={() => adjustVitality(1)}>Hurt</button>
            <button type="button" style={btn("soft", true)} disabled={busy} onClick={() => adjustVitality(-1)}>Heal</button>
          </div>
        </div>
        <div style={card}>
          <div style={label}>Difficulty for the next roll</div>
          <div style={{ display: "flex", gap: 6, marginTop: 8, alignItems: "center" }}>
            <button type="button" style={btn("soft", true)} onClick={() => changeDifficulty((effDiff ?? 5) - 1)}>−</button>
            <input style={{ ...input, width: 70, textAlign: "center", fontSize: 18, fontWeight: 700 }} inputMode="numeric" value={difficulty ?? ""} onChange={e => changeDifficulty(e.target.value)} />
            <button type="button" style={btn("soft", true)} onClick={() => changeDifficulty((effDiff ?? 5) + 1)}>+</button>
          </div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 8 }}>Needed = 100 × difficulty ÷ (difficulty + skill). An opponent who can act has difficulty = their skill × 2 (their skill and their will). The top 10% of the success range is a critical.</div>
        </div>
      </div>

      {/* Latest roll, with the additional roll a critical prompts */}
      {last && (
        <div style={{ ...card, marginBottom: 12, borderColor: resultColor(last.result), position: "sticky", top: 8, zIndex: 2 }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8 }}>
            <div>
              <div style={{ fontSize: 13, color: T.slate500 }}>{chain[0].stat_name} {num(chain[0].skill)} vs difficulty {num(chain[0].difficulty)} · {needsText(chain[0])}</div>
              <div style={{ fontSize: 22, fontWeight: 700, color: resultColor(last.result) }}>
                {chain.map(r => r.roll).join(" + ")}{chain.length > 1 ? ` = ${chainTotal}` : ""} <span style={{ fontSize: 15 }}>{resultText(last.result)}</span>
              </div>
              <div style={{ fontSize: 12, color: T.slate600 }}>
                {chain.reduce((s, r) => s + (Number(r.points) || 0), 0) > 0 && `+${num(chain.reduce((s, r) => s + (Number(r.points) || 0), 0), 1)} skill points`}
                {chain.some(r => Number(r.level_after) > Number(r.level_before)) && ` · ${chain[0].stat_name} is now ${Math.max(...chain.map(r => Number(r.level_after)))}`}
              </div>
            </div>
            {last.extra_pending
              ? <button type="button" style={btn("primary")} disabled={!!rolling} onClick={rollExtra}>Critical! Roll the extra</button>
              : <button type="button" style={btn("soft", true)} onClick={() => setChain([])}>Clear</button>}
          </div>
        </div>
      )}

      {/* The sheet: every group, every stat, one Roll button each */}
      {GROUPS.map(([g, title]) => {
        const rowsOf = stats.filter(s => s.grp === g);
        if (!rowsOf.length) return null;
        const open = openGroups[g];
        return (
          <div key={g} style={{ ...card, marginBottom: 10, padding: 0 }}>
            <button type="button" onClick={() => setOpenGroups(o => ({ ...o, [g]: !o[g] }))}
              style={{ ...btn("soft"), border: "none", width: "100%", textAlign: "left", display: "flex", justifyContent: "space-between", padding: "12px 14px", background: "transparent" }}>
              <span style={{ ...label, color: T.slate700 }}>{title}</span>
              <span style={{ fontSize: 12, color: T.slate500 }}>{open ? "hide" : `${rowsOf.length} shown`}</span>
            </button>
            {open && (
              <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(290px, 1fr))", gap: 0, borderTop: `1px solid ${T.slate100}` }}>
                {rowsOf.map(s => (
                  <div key={s.key} style={{ display: "flex", alignItems: "center", gap: 8, padding: "8px 12px", borderBottom: `1px solid ${T.slate100}`, boxSizing: "border-box" }}>
                    <div style={{ minWidth: 0, flex: 1 }}>
                      <div style={{ fontSize: 13, fontWeight: 600, color: T.slate900, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }} title={s.formula_text || ""}>{s.name}</div>
                      <div style={{ fontSize: 11, color: T.slate500 }}>
                        {needsText(s)}
                        {Number(s.item_bonus) !== 0 && ` · items +${num(s.item_bonus)}`}
                        {Number(s.earned_levels) > 0 && ` · trained +${num(s.earned_levels)}`}
                        {s.trainable && Number(s.next_level_cost) > 0 && ` · ${num(s.skill_points)}/${num(s.next_level_cost)} pts`}
                      </div>
                    </div>
                    <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900, minWidth: 34, textAlign: "right" }}>{num(s.value)}</div>
                    {isParent && s.kind !== "derived" && (
                      <button type="button" style={btn("soft", true)} title="Set by hand (special means)" onClick={() => setInput(s)}>Set</button>
                    )}
                    <button type="button" style={btn("primary", true)} disabled={!!rolling} onClick={() => roll(s)}>{rolling === s.key ? "…" : "Roll"}</button>
                  </div>
                ))}
              </div>
            )}
          </div>
        );
      })}

      {/* Items and coins */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))", gap: 10, marginBottom: 12 }}>
        <div style={card}>
          <div style={label}>Items</div>
          {(sheet.items || []).length === 0 && <div style={{ fontSize: 13, color: T.slate500, marginTop: 6 }}>Nothing carried yet.</div>}
          {(sheet.items || []).map(it => (
            <div key={it.id} style={{ display: "flex", alignItems: "center", gap: 8, padding: "8px 0", borderBottom: `1px solid ${T.slate100}` }}>
              <div style={{ flex: 1, minWidth: 0, opacity: it.equipped ? 1 : 0.5 }}>
                <div style={{ fontSize: 13, fontWeight: 600, color: T.slate900 }}>{it.name}</div>
                <div style={{ fontSize: 11, color: T.slate500 }}>
                  {it.stat_name ? `${Number(it.bonus) >= 0 ? "+" : ""}${it.bonus} ${it.stat_name}` : "no bonus"}
                  {it.uses_left != null && ` · ${it.uses_left} uses left`}
                  {!it.equipped && " · not equipped"}
                </div>
              </div>
              {it.uses_left != null && it.uses_left > 0 && <button type="button" style={btn("soft", true)} onClick={() => useItem(it)}>Use</button>}
              <button type="button" style={btn("soft", true)} onClick={() => toggleItem(it)}>{it.equipped ? "Unequip" : "Equip"}</button>
              <button type="button" style={btn("danger", true)} onClick={() => deleteItem(it)}>✕</button>
            </div>
          ))}
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(120px, 1fr))", gap: 6, marginTop: 10 }}>
            <input style={{ ...input, gridColumn: isPhone ? "1 / -1" : "span 2" }} placeholder="Item name" value={item.name} onChange={e => setItem(i => ({ ...i, name: e.target.value }))} />
            <select style={input} value={item.stat_key} onChange={e => setItem(i => ({ ...i, stat_key: e.target.value }))}>
              <option value="">Boosts…</option>
              {(defs || []).map(d => <option key={d.key} value={d.key}>{d.name}</option>)}
            </select>
            <input style={input} inputMode="numeric" placeholder="+" value={item.bonus} onChange={e => setItem(i => ({ ...i, bonus: e.target.value }))} title="Bonus" />
            <input style={input} inputMode="numeric" placeholder="Uses (blank = always)" value={item.uses_left} onChange={e => setItem(i => ({ ...i, uses_left: e.target.value }))} />
            <button type="button" style={btn("primary")} disabled={busy || !item.name.trim()} onClick={addItem}>Add</button>
          </div>
        </div>
        <div style={card}>
          <div style={label}>Coins</div>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(90px, 1fr))", gap: 6, marginTop: 8 }}>
            {COINS.map(([k, name]) => (
              <label key={k} style={{ fontSize: 11, color: T.slate500 }}>{name}
                <input style={{ ...input, width: "100%", marginTop: 2 }} inputMode="numeric" value={coins?.[k] ?? ""} onChange={e => setCoins(c => ({ ...(c || {}), [k]: e.target.value }))} />
              </label>
            ))}
          </div>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 8, gap: 8, flexWrap: "wrap" }}>
            <div style={{ fontSize: 11, color: T.slate500 }}>1 Platinum = 100 Gold · 1 Gold = 100 Silver · 1 Silver = 100 Copper</div>
            <button type="button" style={btn("primary", true)} disabled={busy} onClick={saveCoins}>Save</button>
          </div>
        </div>
      </div>

      {/* Roll log */}
      <div style={card}>
        <div style={label}>Recent rolls</div>
        {rolls.length === 0 && <div style={{ fontSize: 13, color: T.slate500, marginTop: 6 }}>No rolls yet.</div>}
        {rolls.map(r => (
          <div key={r.roll_id} style={{ display: "flex", justifyContent: "space-between", gap: 8, padding: "6px 0", borderBottom: `1px solid ${T.slate100}`, fontSize: 12 }}>
            <div style={{ color: T.slate700, minWidth: 0 }}>
              {r.parent_roll_id ? "↳ extra roll · " : ""}{r.stat_name || r.stat_key} {num(r.skill)} vs {num(r.difficulty)}
              {Number(r.points) > 0 && <span style={{ color: T.slate500 }}> · +{num(r.points, 1)} pts</span>}
              {Number(r.level_after) > Number(r.level_before) && <span style={{ color: T.gold, fontWeight: 700 }}> · level up to {r.level_after}</span>}
            </div>
            <div style={{ whiteSpace: "nowrap", color: resultColor(r.result), fontWeight: 700 }}>{r.roll} <span style={{ fontWeight: 400, color: T.slate500 }}>{when(r.created_at)}</span></div>
          </div>
        ))}
      </div>
      {sheet.notes && <div style={{ ...card, marginTop: 10, fontSize: 13, color: T.slate700, whiteSpace: "pre-wrap" }}>{sheet.notes}</div>}
    </div>
  );
}

// ── Creatures ────────────────────────────────────────────────────────────────
// Card text is markdown kept verbatim from the manual card. The shared renderer runs a line
// that ends in two spaces into the next one, so each such line goes through it on its own.
const cardHtml = (text) => String(text || "").split(/ {2,}\n/)
  .map(part => mdToHtml(part)).join("")
  .replace(/<p>/g, '<p style="margin:0 0 6px 0">');
function CardText({ text, style }) {
  if (!text) return null;
  return <div className="newtworks-handbook-body" style={{ fontSize: 13, lineHeight: 1.6, ...style }} dangerouslySetInnerHTML={{ __html: cardHtml(text) }} />;
}
const signed = (n) => { const v = Number(n) || 0; return v < 0 ? `−${Math.abs(v)}` : `+${v}`; };
const tag = (tone) => ({
  fontSize: 11, fontWeight: 700, borderRadius: 999, padding: "2px 8px", whiteSpace: "nowrap", flexShrink: 0, boxSizing: "border-box",
  background: tone === "on" ? T.greenLt : tone === "gold" ? T.goldLt : T.slate100,
  color: tone === "off" ? T.slate500 : T.slate800,
  border: `1px solid ${tone === "on" ? T.green : tone === "gold" ? T.gold : T.slate200}`,
});

function CreatureList({ isParent, onOpen, hrefFor, onError }) {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc("rpg_creature_list");
      if (!alive) return;
      if (error) onError(error.message);
      setRows(Array.isArray(data) ? data : []);
      setLoading(false);
    })();
    return () => { alive = false; };
  }, [onError]);

  if (loading) return <div style={{ color: T.slate500, fontSize: 13 }}>Loading</div>;

  return (
    <div>
      <div style={{ ...label, marginBottom: 10 }}>Creatures</div>
      {rows.length === 0 && (
        <div style={{ ...card, color: T.slate500, fontSize: 13 }}>
          {isParent ? "No creature cards yet." : "No creatures met yet. They show up here when the game master reveals them."}
        </div>
      )}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))", gap: 10 }}>
        {rows.map(r => (
          <TabLink key={r.id} href={hrefFor(r.id)} onSelect={() => onOpen(r.id)}
            style={{ ...card, display: "block", textDecoration: "none", color: "inherit", cursor: "pointer", borderLeft: `4px solid ${r.color || T.slate400}` }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 8 }}>
              <div style={{ fontWeight: 700, fontSize: 15, color: T.slate900, minWidth: 0 }}>{r.name}</div>
              {isParent && <span style={tag(r.shown_to_players ? "on" : "off")}>{r.shown_to_players ? "Shown" : "Hidden"}</span>}
            </div>
            {isParent && <div style={{ fontSize: 12, color: T.slate500, marginTop: 2 }}>Attack {num(r.attack_skill)} · Defense {num(r.defense_skill)} · Vitality {num(r.vitality)}</div>}
            {r.epigraph && <div style={{ fontSize: 12, color: T.slate600, fontStyle: "italic", marginTop: 6, lineHeight: 1.5 }}>{r.epigraph}</div>}
          </TabLink>
        ))}
      </div>
      {isParent && rows.length > 0 && <div style={{ fontSize: 12, color: T.slate500, marginTop: 10 }}>Players only see a creature after you open it and tap Show to players.</div>}
    </div>
  );
}

// A picture for the card. Pictures live in the private rpg-images bucket: everyone signed in can
// see them, parents upload. No picture yet → a parent gets an upload control and a ready-made
// prompt to paste into ChatGPT; players just see the empty frame.
const plainText = (t) => String(t || "").replace(/[*_`#>]/g, "").replace(/\s+/g, " ").trim();
const imagePrompt = (c) => [
  `Illustrate ${c.name}${c.type_line ? ` (${c.type_line})` : ""} for a family fantasy tabletop game.`,
  plainText(c.lore),
  c.haunts ? `Setting: ${plainText(c.haunts)}.` : "",
  "Painted storybook style, dramatic natural lighting, the creature centered and fully in frame, square image, no words or letters anywhere.",
].filter(Boolean).join(" ");

function CreaturePicture({ c, gm, onError, onSaved }) {
  const [url, setUrl] = useState(null);
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    let alive = true;
    setUrl(null);
    if (!c.image_path) return undefined;
    (async () => {
      const { data, error } = await supabase.storage.from("rpg-images").createSignedUrl(c.image_path, 3600);
      if (!alive) return;
      if (error) { onError(error.message); return; }
      setUrl(data?.signedUrl || null);
    })();
    return () => { alive = false; };
  }, [c.image_path, onError]);

  const upload = async (file) => {
    if (!file || busy) return;
    setBusy(true);
    const safe = file.name.replace(/[^A-Za-z0-9._-]/g, "_");
    const path = `${c.key || c.id}/${Date.now()}_${safe}`;
    const up = await supabase.storage.from("rpg-images").upload(path, file, { contentType: file.type, upsert: true });
    if (up.error) { setBusy(false); onError(up.error.message); return; }
    const { error } = await supabase.from("rpg_creatures").update({ image_path: path }).eq("id", c.id);
    setBusy(false);
    if (error) { onError(error.message); return; }
    onSaved();
  };
  const copy = async () => {
    try { await navigator.clipboard.writeText(imagePrompt(c)); setCopied(true); setTimeout(() => setCopied(false), 1500); } catch (e) { onError("Copy failed. Select the text and copy it."); }
  };
  const picker = (
    <label style={{ ...btn("soft", true), display: "inline-block", cursor: busy ? "wait" : "pointer" }}>
      {busy ? "Uploading…" : url ? "Replace picture" : "Upload a picture"}
      <input type="file" accept="image/png,image/jpeg,image/webp" style={{ display: "none" }} disabled={busy} onChange={e => upload(e.target.files?.[0])} />
    </label>
  );

  return (
    <div style={{ display: "grid", gap: 8 }}>
      {url ? (
        <img src={url} alt={c.name} style={{ width: "100%", borderRadius: 10, display: "block", border: `1px solid ${T.slate200}` }} />
      ) : (
        <div style={{ aspectRatio: "1 / 1", borderRadius: 10, border: `2px dashed ${T.slate200}`, background: T.slate50, display: "flex", alignItems: "center", justifyContent: "center", color: T.slate500, fontSize: 13, textAlign: "center", padding: 12, boxSizing: "border-box" }}>
          No picture yet
        </div>
      )}
      {gm && picker}
      {gm && !url && (
        <div>
          <div style={{ fontSize: 12, color: T.slate600, marginBottom: 4 }}>Ask ChatGPT for one. Copy this, paste it there, then upload what it makes.</div>
          <pre style={{ margin: 0, fontSize: 12, lineHeight: 1.5, whiteSpace: "pre-wrap", wordBreak: "break-word", background: T.slate900, color: T.slate100, borderRadius: 8, padding: 10, boxSizing: "border-box" }}>{imagePrompt(c)}</pre>
          <button type="button" style={{ ...btn("soft", true), marginTop: 6 }} onClick={copy}>{copied ? "Copied" : "Copy the prompt"}</button>
        </div>
      )}
    </div>
  );
}

// A section of the card that folds shut. The busiest parts start closed.
function Fold({ title, open: startOpen, children }) {
  const [open, setOpen] = useState(!!startOpen);
  return (
    <div style={{ ...card, marginBottom: 12 }}>
      <button type="button" onClick={() => setOpen(!open)}
        style={{ display: "flex", width: "100%", alignItems: "center", justifyContent: "space-between", gap: 8, background: "none", border: "none", padding: 0, cursor: "pointer", textAlign: "left" }}>
        <span style={label}>{title}</span>
        <span style={{ fontSize: 12, color: T.slate500 }}>{open ? "Hide" : "Show"}</span>
      </button>
      {open && <div style={{ marginTop: 6 }}>{children}</div>}
    </div>
  );
}

function CreatureCard({ id, onBack, backHref, onError }) {
  const [c, setC] = useState(null);
  const [missing, setMissing] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("rpg_creature_card", { p_creature_id: id });
    if (error) { onError(error.message); setMissing(true); return; }
    if (!data) { setMissing(true); return; }
    setMissing(false);
    setC(data);
  }, [id, onError]);
  useEffect(() => { load(); }, [load]);

  const toggleShown = async () => {
    if (!c || busy) return;
    setBusy(true);
    const { error } = await supabase.from("rpg_creatures").update({ shown_to_players: !c.shown_to_players }).eq("id", id);
    setBusy(false);
    if (error) { onError(error.message); return; }
    load();
  };

  const backLink = (
    <a href={backHref} onClick={(e) => handleModuleLinkClick(e, onBack)}
      style={{ ...btn("soft", true), textDecoration: "none", display: "inline-block" }}>← Creatures</a>
  );

  if (missing) return <div style={{ ...card, fontSize: 13, color: T.slate700, display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>That creature is not on the list. {backLink}</div>;
  if (!c) return <div style={{ color: T.slate500, fontSize: 13 }}>Loading</div>;

  const gm = !!c.is_gm;
  const names = Array.isArray(c.whispered_names) ? c.whispered_names : [];
  const accent = c.color || T.slate700;

  return (
    <div>
      <ManualBodyStyles />
      <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap", marginBottom: 10 }}>
        {backLink}
        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900 }}>{c.name}</div>
          {c.scholarly_name && <div style={{ fontSize: 13, color: T.slate500, fontStyle: "italic" }}>{c.scholarly_name}</div>}
        </div>
        {gm && (
          <button type="button" style={btn(c.shown_to_players ? "soft" : "primary", true)} disabled={busy} onClick={toggleShown}
            title={c.shown_to_players ? "Players can see its picture, names, haunts and lore" : "Players cannot see this creature yet"}>
            {busy ? "Saving…" : c.shown_to_players ? "Hide from players" : "Show to players"}
          </button>
        )}
      </div>

      {/* What the world knows: picture and lore. The only part players see, once a parent shows it. */}
      <div style={{ ...card, marginBottom: 12, borderTop: `4px solid ${accent}` }}>
        <div style={{ display: "flex", gap: 14, flexWrap: "wrap" }}>
          <div style={{ flex: "1 1 200px", maxWidth: 320 }}>
            <CreaturePicture c={c} gm={gm} onError={onError} onSaved={load} />
          </div>
          <div style={{ flex: "2 1 260px", minWidth: 0 }}>
            {c.epigraph && <div style={{ fontSize: 15, fontStyle: "italic", color: T.slate800, borderLeft: `3px solid ${accent}`, paddingLeft: 12, marginBottom: 12, lineHeight: 1.5 }}>{c.epigraph}</div>}
            <CardText text={c.lore} />
            {names.length > 0 && (
              <div style={{ marginTop: 10 }}>
                <div style={{ fontSize: 12, color: T.slate500, marginBottom: 4 }}>{c.whispered_label || "Other names"}</div>
                <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
                  {names.map(n => <span key={n} style={{ fontSize: 12, color: T.slate800, background: T.slate100, border: `1px solid ${T.slate200}`, borderRadius: 999, padding: "3px 10px", boxSizing: "border-box" }}>{n}</span>)}
                </div>
              </div>
            )}
            {c.haunts && <div style={{ fontSize: 13, color: T.slate700, marginTop: 10 }}><span style={{ color: T.slate500 }}>Known haunts:</span> {c.haunts}</div>}
          </div>
        </div>
        {gm && <div style={{ fontSize: 11, color: T.slate500, marginTop: 10 }}>{c.shown_to_players ? "Players can see this part of the card." : "Players cannot see this creature yet."} Everything below is for the game master only.</div>}
      </div>

      {gm && <CreatureGmCard c={c} accent={accent} />}
    </div>
  );
}

function TableNumber({ big, small }) {
  return (
    <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: "8px 10px", boxSizing: "border-box" }}>
      <div style={{ fontSize: 22, fontWeight: 700, color: T.slate900, lineHeight: 1.2 }}>{big}</div>
      <div style={{ fontSize: 12, color: T.slate500 }}>{small}</div>
    </div>
  );
}

// The game master's half of the card, in folds: the numbers the table uses, the actions with what
// each one rolls, then the printed d20 stat block, the rumor table and the tip. Reading parts start shut.
function CreatureGmCard({ c, accent }) {
  const actions = Array.isArray(c.actions) ? c.actions : [];
  const ofKind = (k) => actions.filter(a => a.kind === k);
  const t = c.table || {};
  const mult = num(t.will_multiplier);
  const rumors = Array.isArray(c.rumors) ? c.rumors : [];

  const statRow = (name, value) => (value ? (
    <div style={{ fontSize: 13, color: T.slate700, padding: "3px 0" }}><span style={{ fontWeight: 700, color: T.slate900 }}>{name}</span> {value}</div>
  ) : null);
  // What the action does at the table: the skill it rolls, the stat the target defends with, and the note.
  const tableLine = (a) => (a.skill == null && !a.table_note ? null : (
    <div style={{ marginTop: 4 }}>
      {a.skill != null && <div style={{ fontSize: 12, color: T.blue, fontWeight: 700 }}>Rolls {num(a.skill)} against {a.against_name || "the target"} × {mult}</div>}
      {a.table_note && <div style={{ fontSize: 12, color: T.slate600, lineHeight: 1.5 }}>{a.table_note}</div>}
    </div>
  ));
  const group = (title, list, intro) => (list.length === 0 ? null : (
    <div style={{ marginBottom: 10 }}>
      <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, borderBottom: `2px solid ${accent}`, paddingBottom: 4 }}>{title}</div>
      {intro && <CardText text={intro} style={{ marginTop: 6 }} />}
      {list.map(a => (
        <div key={a.id} style={{ padding: "8px 0", borderTop: `1px solid ${T.slate100}` }}>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 2 }}>{a.heading || a.name}</div>
          <CardText text={a.description} />
          {tableLine(a)}
        </div>
      ))}
    </div>
  ));

  return (
    <>
      {/* The character-scale numbers the table uses (rule creature_conversion). Difficulties come from rpg_difficulty. */}
      <div style={{ ...card, marginBottom: 12, background: T.blueLt, borderColor: T.blue }}>
        <div style={label}>At the table</div>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10, marginTop: 8 }}>
          <TableNumber big={num(t.vitality)} small="Vitality" />
          <TableNumber big={num(t.attack_skill)} small={`Attack · rolls against ${t.attacks_roll_against || "Evade Enemy"} × ${mult}`} />
          <TableNumber big={num(t.difficulty_to_hit)} small={`Difficulty to hit it (defense ${num(t.defense_skill)} × ${mult})`} />
          <TableNumber big={num(t.difficulty_to_hit_still)} small="Difficulty to hit it asleep or held" />
          <TableNumber big={num(t.strength_skill)} small="Strength" />
          <TableNumber big={num(t.will_skill)} small="Will · persuade or frighten it against this × 2" />
          <TableNumber big={num(t.stealth_skill)} small="Stealth · spot it hidden against this × 2" />
          <TableNumber big={num(t.awareness_skill)} small="Awareness · sneak past it against this × 2" />
          {Number(c.legendary_per_round) > 0 && <TableNumber big={num(c.legendary_per_round)} small="Legendary actions a round" />}
        </div>
      </div>

      <Fold title="Actions and traits" open>
        {group("Actions", ofKind("action"))}
        {group("Bonus actions", ofKind("bonus_action"))}
        {group("Reactions", ofKind("reaction"))}
        {group(`Legendary actions (${num(c.legendary_per_round)} a round)`, ofKind("legendary"), c.legendary_intro)}
        {group(c.lair_title ? `Lair actions (${c.lair_title})` : "Lair actions", ofKind("lair"), c.lair_intro)}
        {group("Traits", ofKind("trait"))}
      </Fold>

      <Fold title="Printed stat block (the d20 numbers, for reading)">
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>{c.card_title || c.name}</div>
        {c.type_line && <div style={{ fontSize: 13, fontStyle: "italic", color: T.slate600 }}>{c.type_line}</div>}
        <div style={{ marginTop: 8 }}>
          {statRow("Armor Class", c.armor_text)}
          {statRow("Hit Points", c.hit_points_text)}
          {statRow("Speed", c.speed_text)}
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(90px, 1fr))", gap: 6, margin: "10px 0" }}>
          {(Array.isArray(c.abilities) ? c.abilities : []).map(a => (
            <div key={a.key} style={{ textAlign: "center", background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "6px 4px", boxSizing: "border-box" }}>
              <div style={{ fontSize: 11, fontWeight: 700, color: T.slate500 }}>{a.label}</div>
              <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>{a.score} <span style={{ fontSize: 12, fontWeight: 600, color: T.slate500 }}>({signed(a.mod)})</span></div>
            </div>
          ))}
        </div>
        {statRow("Saving Throws", c.saving_throws_text)}
        {statRow("Skills", c.skills_text)}
        {statRow("Damage Vulnerabilities", c.damage_vulnerabilities)}
        {statRow("Damage Resistances", c.damage_resistances)}
        {statRow("Damage Immunities", c.damage_immunities)}
        {statRow("Condition Immunities", c.condition_immunities)}
        {statRow("Senses", c.senses)}
        {statRow("Languages", c.languages)}
        {statRow("Challenge Rating", c.challenge_text)}
      </Fold>

      {rumors.length > 0 && (
        <Fold title="Player rumor table">
          {c.rumor_title && <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900, marginTop: 4 }}>{c.rumor_title}</div>}
          {c.rumor_intro && <div style={{ fontSize: 13, fontStyle: "italic", color: T.slate600, marginTop: 2 }}>{c.rumor_intro}</div>}
          <div style={{ marginTop: 8 }}>
            {rumors.map(r => (
              <div key={r.roll} style={{ display: "flex", gap: 10, alignItems: "baseline", padding: "7px 0", borderTop: `1px solid ${T.slate100}` }}>
                <div style={{ width: 22, flexShrink: 0, textAlign: "center", fontWeight: 700, color: T.slate900 }}>{r.roll}</div>
                <CardText text={r.text} style={{ flex: 1, minWidth: 0 }} />
                {r.truth === "partial" && <span style={tag("gold")}>Partly true</span>}
                {r.truth === "true" && <span style={tag("on")}>True</span>}
              </div>
            ))}
          </div>
          {c.rumor_note && <div style={{ fontSize: 12, fontStyle: "italic", color: T.slate500, marginTop: 6 }}>{c.rumor_note}</div>}
        </Fold>
      )}

      {c.gm_tip && (
        <div style={{ ...card, marginBottom: 12, background: T.goldLt, borderColor: T.gold }}>
          <div style={label}>DM Flavor Tip</div>
          <CardText text={c.gm_tip} style={{ marginTop: 6 }} />
        </div>
      )}
    </>
  );
}


// ── Rules ────────────────────────────────────────────────────────────────────
// Everything here comes from rpg_rules_page(): the manual text verbatim (rpg_rules), every
// formula spelled out by rpg_formula_text() exactly as the sheet shows it, and the level-cost
// table from rpg_level_cost(). The calculator asks rpg_needed(), the function a real roll uses.
const howFigured = (s) => (s.kind === "rolled" ? "Rolled when the character is made"
  : s.kind === "fixed" ? `Starts at ${num(s.default_value)}${s.trainable ? ", grows by training" : ""}`
  : (s.formula_text || "—"));
const th = { textAlign: "left", fontSize: 11, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.05em", padding: "8px 12px", borderBottom: `1px solid ${T.slate100}`, whiteSpace: "nowrap" };
const td = { padding: "7px 12px", borderBottom: `1px solid ${T.slate100}`, verticalAlign: "top" };

// Rule bodies are markdown. A block with single line breaks (the roll check formulas) would be
// run together by the shared renderer, so each block's lines are rendered one at a time and
// joined with a line break. List blocks go through whole so they stay lists.
const inlineOf = (line) => { const h = mdToHtml(line).trim(); const m = /^<p>([\s\S]*)<\/p>$/.exec(h); return m ? m[1] : h; };
const ruleHtml = (text) => String(text || "").split(/\n[ \t]*\n/).map(block => {
  const lines = block.split(/\r?\n/).map(l => l.trim()).filter(Boolean);
  if (!lines.length) return "";
  if (/^([-*+]|\d+[.)])\s/.test(lines[0])) return mdToHtml(lines.join("\n"));
  return `<p>${lines.map(inlineOf).join("<br/>")}</p>`;
}).join("").replace(/<p>/g, '<p style="margin:0 0 8px 0">');
function RuleText({ text }) {
  if (!text) return null;
  return <div className="newtworks-handbook-body" style={{ fontSize: 13, lineHeight: 1.6, color: T.slate700, marginTop: 6 }} dangerouslySetInnerHTML={{ __html: ruleHtml(text) }} />;
}

function RulesTab({ onError }) {
  const [page, setPage] = useState(null);
  const [sub, setSub] = useState("");

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc("rpg_rules_page");
      if (!alive) return;
      if (error) { onError(error.message); return; }
      setPage(data || null);
    })();
    return () => { alive = false; };
  }, [onError]);

  if (!page) return <div style={{ color: T.slate500, fontSize: 13 }}>Loading</div>;

  const rules = Array.isArray(page.rules) ? page.rules : [];
  const stats = Array.isArray(page.stats) ? page.stats : [];
  const levels = Array.isArray(page.level_costs) ? page.level_costs : [];
  const settings = Array.isArray(page.settings) ? page.settings : [];
  const hasRule = (k) => rules.some(r => r.key === k);
  const calculator = <RollCalculator defaultDifficulty={page.default_difficulty} onError={onError} />;
  const levelTable = <LevelCostTable rows={levels} multiplier={page.level_cost_multiplier} />;

  // One subtab per section, in the order the cards come (rpg_rules.section, sort_order), plus Tables.
  const sections = [];
  rules.forEach(r => { const s = r.section || "Rules"; if (!sections.includes(s)) sections.push(s); });
  const tabs = [...sections, "Tables"];
  const cur = tabs.includes(sub) ? sub : tabs[0];
  const shown = rules.filter(r => (r.section || "Rules") === cur);

  return (
    <div>
      <ManualBodyStyles />
      <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginBottom: 12 }}>
        {tabs.map(t => <button key={t} type="button" style={btn(cur === t ? "primary" : "soft", true)} onClick={() => setSub(t)}>{t}</button>)}
      </div>
      {rules.length === 0 && <div style={{ ...card, color: T.slate500, fontSize: 13, marginBottom: 10 }}>No rules written yet.</div>}
      {cur !== "Tables" && shown.map(r => (
        <div key={r.key} style={{ ...card, marginBottom: 10 }}>
          <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}>{r.title}</div>
          <RuleText text={r.body} />
          {r.key === "roll_check" && calculator}
          {r.key === "skill_gain" && levelTable}
        </div>
      ))}
      {cur === "Tables" && (
        <>
          {!hasRule("roll_check") && <div style={{ ...card, marginBottom: 10 }}>{calculator}</div>}
          {!hasRule("skill_gain") && <div style={{ ...card, marginBottom: 10 }}>{levelTable}</div>}
          <FormulaTable stats={stats} />
          {page.is_gm && settings.length > 0 && (
            <div style={{ ...card, marginTop: 10 }}>
              <div style={label}>The numbers the game runs on</div>
              <div style={{ fontSize: 12, color: T.slate500, marginTop: 2 }}>Game master only.</div>
              {settings.map(s => (
                <div key={s.key} style={{ display: "flex", justifyContent: "space-between", gap: 10, padding: "6px 0", borderBottom: `1px solid ${T.slate100}`, fontSize: 13 }}>
                  <div style={{ color: T.slate700, minWidth: 0 }}>{s.label}</div>
                  <div style={{ fontWeight: 700, color: T.slate900, whiteSpace: "nowrap" }}>{Number.isFinite(Number(s.value)) ? Number(s.value).toLocaleString("en-US") : "—"}</div>
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </div>
  );
}


// Try a roll: pick a skill and a difficulty, see what a d100 needs. rpg_needed() answers, the
// same function a real roll calls, so this can never disagree with the sheet. Against an
// opponent, rpg_difficulty() first turns their skill into the difficulty (× 2 when they can act,
// for their skill and their will), and that number is what rpg_needed() gets.
function RollCalculator({ defaultDifficulty, onError }) {
  const [skill, setSkill] = useState("5");
  const [difficulty, setDifficulty] = useState(String(Number.isFinite(Number(defaultDifficulty)) ? Number(defaultDifficulty) : 5));
  const [opposed, setOpposed] = useState(false);
  const [calc, setCalc] = useState(null);
  const seq = useRef(0);

  useEffect(() => {
    const s = Number(skill), d = Number(difficulty);
    if (skill === "" || difficulty === "" || !Number.isFinite(s) || !Number.isFinite(d)) { setCalc(null); return undefined; }
    const mine = ++seq.current;
    const t = setTimeout(async () => {
      let diff = Math.max(0, d);
      if (opposed) {
        const r = await supabase.rpc("rpg_difficulty", { p_skill: diff, p_can_act: true });
        if (mine !== seq.current) return;
        if (r.error) { onError(r.error.message); return; }
        diff = Number(r.data) || 0;
      }
      const { data, error } = await supabase.rpc("rpg_needed", { p_skill: Math.max(0, s), p_difficulty: diff });
      if (mine !== seq.current) return;
      if (error) { onError(error.message); return; }
      setCalc(data ? { ...data, difficulty: diff } : null);
    }, 200);
    return () => clearTimeout(t);
  }, [skill, difficulty, opposed, onError]);

  const needed = calc ? Math.ceil(Number(calc.needed) || 0) : null;
  const crit = calc ? Math.ceil(Number(calc.critical) || 0) : null;
  const chance = needed == null ? null : Math.max(0, Math.min(100, 101 - needed));

  return (
    <div style={{ marginTop: 10, background: T.blueLt, border: `1px solid ${T.blue}`, borderRadius: 10, padding: 12, boxSizing: "border-box" }}>
      <div style={label}>Try a roll</div>
      <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginTop: 8 }}>
        <button type="button" style={btn(!opposed ? "primary" : "soft", true)} onClick={() => setOpposed(false)}>Against a difficulty</button>
        <button type="button" style={btn(opposed ? "primary" : "soft", true)} onClick={() => setOpposed(true)}>Against an opponent</button>
      </div>
      <div style={{ fontSize: 12, color: T.slate600, marginTop: 6 }}>
        {opposed ? "An opponent who can act: the difficulty is their skill × 2, for their skill and their will to use it. Skill 5 against skill 5 is difficulty 10 and needs 67 or more."
                 : "A fixed challenge, or a defender who cannot act, is just its difficulty number. Skill 5 against difficulty 5 needs 50 or more."}
      </div>
      <div style={{ display: "flex", gap: 16, flexWrap: "wrap", marginTop: 8 }}>
        <NumberBox title="Your skill" value={skill} onChange={setSkill} />
        <NumberBox title={opposed ? "Their skill" : "Difficulty"} value={difficulty} onChange={setDifficulty} />
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(120px, 1fr))", gap: 10, marginTop: 10 }}>
        {opposed && <TableNumber big={calc == null ? "—" : num(calc.difficulty)} small="Difficulty (skill and will)" />}
        <TableNumber big={needed == null ? "—" : `${needed}+`} small="Succeeds" />
        <TableNumber big={crit == null ? "—" : `${crit}+`} small="Critical" />
        <TableNumber big={chance == null ? "—" : `${chance} in 100`} small="Chance to succeed" />
      </div>
      {needed != null && (
        <div style={{ fontSize: 12, color: T.slate600, marginTop: 8 }}>
          Roll a d100. {needed <= 1 ? "Any roll succeeds." : `${needed} or more succeeds.`} {crit} or more is a critical and prompts an extra roll.
        </div>
      )}
    </div>
  );
}

function NumberBox({ title, value, onChange }) {
  const n = Math.max(0, Number(value) || 0);
  return (
    <div>
      <div style={{ fontSize: 11, color: T.slate500, fontWeight: 700 }}>{title}</div>
      <div style={{ display: "flex", gap: 6, marginTop: 4, alignItems: "center" }}>
        <button type="button" style={btn("soft", true)} onClick={() => onChange(String(Math.max(0, n - 1)))}>−</button>
        <input style={{ ...input, width: 70, textAlign: "center", fontSize: 18, fontWeight: 700 }} inputMode="numeric" value={value} onChange={e => onChange(e.target.value)} />
        <button type="button" style={btn("soft", true)} onClick={() => onChange(String(n + 1))}>+</button>
      </div>
    </div>
  );
}

// Skill points to reach the next level, one cell per level, from rpg_level_cost().
function LevelCostTable({ rows, multiplier }) {
  if (!rows.length) return null;
  return (
    <div style={{ marginTop: 10 }}>
      <div style={label}>Skill points to reach the next level</div>
      <div style={{ fontSize: 12, color: T.slate500, marginTop: 2, marginBottom: 8 }}>{num(multiplier)} × (old level + new level)</div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(105px, 1fr))", gap: 6 }}>
        {rows.map(r => (
          <div key={r.level} style={{ background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 8, padding: "6px 8px", boxSizing: "border-box", textAlign: "center" }}>
            <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>{r.level} → {r.next_level}</div>
            <div style={{ fontSize: 11, color: T.slate500 }}>{Number(r.points).toLocaleString("en-US")} pts</div>
          </div>
        ))}
      </div>
    </div>
  );
}

// Every stat on the sheet and how it is figured, in the sheet's groups and order.
function FormulaTable({ stats }) {
  const [openGroups, setOpenGroups] = useState(() => Object.fromEntries(GROUPS.map(([g]) => [g, true])));
  if (!stats.length) return null;
  return (
    <div>
      <div style={{ ...label, margin: "14px 0 8px" }}>How every number on the sheet is figured</div>
      {GROUPS.map(([g, title]) => {
        const rowsOf = stats.filter(s => s.grp === g);
        if (!rowsOf.length) return null;
        const open = openGroups[g];
        return (
          <div key={g} style={{ ...card, marginBottom: 10, padding: 0 }}>
            <button type="button" onClick={() => setOpenGroups(o => ({ ...o, [g]: !o[g] }))}
              style={{ ...btn("soft"), border: "none", width: "100%", textAlign: "left", display: "flex", justifyContent: "space-between", padding: "12px 14px", background: "transparent" }}>
              <span style={{ ...label, color: T.slate700 }}>{title}</span>
              <span style={{ fontSize: 12, color: T.slate500 }}>{open ? "hide" : `${rowsOf.length} shown`}</span>
            </button>
            {open && (
              <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch", borderTop: `1px solid ${T.slate100}` }}>
                <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
                  <thead>
                    <tr>
                      <th style={th}>Stat</th>
                      <th style={th}>How it is figured</th>
                      <th style={{ ...th, textAlign: "center" }}>Can train</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rowsOf.map(s => (
                      <tr key={s.key}>
                        <td style={{ ...td, whiteSpace: "nowrap" }}>
                          <span style={{ fontWeight: 600, color: T.slate900 }}>{s.name}</span>
                          {s.abbr && <span style={{ color: T.slate500, fontSize: 11 }}> {s.abbr}</span>}
                        </td>
                        <td style={{ ...td, color: T.slate700 }}>{howFigured(s)}</td>
                        <td style={{ ...td, textAlign: "center", color: T.green, fontWeight: 700 }}>{s.trainable ? "✓" : ""}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ── Play: fights, turns, attacks and the log (step 5) ──────────────────────
// Every screen reads one payload, rpg_session_state(id). Whoever just did something sends a "refresh" nudge on
// the fight's broadcast channel and the other screens re-read. The database never broadcasts: realtime.messages
// has no partitions on this project, so writes there fail quietly. A 10-second re-read covers a lost nudge.
// Same pattern as the trivia night.

const CREATURE_SKILLS = [["attack", "Attack"], ["defense", "Defense"], ["strength", "Strength"], ["will", "Will"], ["stealth", "Stealth"], ["awareness", "Awareness"], ["agility", "Agility"]];
const ACTION_GROUPS = [["action", "Actions"], ["bonus_action", "Bonus actions"], ["reaction", "Reactions"], ["legendary", "Legendary actions"], ["lair", "Lair actions"]];
const fightStatus = (s) => (s?.status === "setup" ? "Setting up" : s?.status === "ended" ? "Over" : `Round ${s?.round || 1}`);
const isDown = (p) => (p?.vitality_left != null ? Number(p.vitality_left) <= 0 : Number(p?.vitality_share) <= 0);
const pill = (color, bg) => ({ fontSize: 11, fontWeight: 700, color, background: bg, borderRadius: 999, padding: "2px 8px", whiteSpace: "nowrap" });
const hint = { fontSize: 12, color: T.slate500, marginTop: 4 };

function useLiveChannel(name, onNudge) {
  const chRef = useRef(null);
  useEffect(() => {
    if (!name) return undefined;
    const ch = supabase.channel(name);
    ch.on("broadcast", { event: "refresh" }, () => { onNudge(); }).subscribe();
    chRef.current = ch;
    const t = setInterval(onNudge, 10000);
    return () => { clearInterval(t); chRef.current = null; supabase.removeChannel(ch); };
  }, [name, onNudge]);
  return useCallback(() => {
    const ch = chRef.current;
    if (!ch) return;
    try { ch.send({ type: "broadcast", event: "refresh", payload: {} }); } catch (_) { /* the 10-second re-read covers it */ }
  }, []);
}

function FightList({ isParent, onOpen, hrefFor, onError }) {
  const [rows, setRows] = useState(null);
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("rpg_session_list");
    if (error) { onError(error.message); return; }
    setRows(Array.isArray(data) ? data : []);
  }, [onError]);
  useEffect(() => { load(); }, [load]);
  const nudge = useLiveChannel(`rpg_fights:${AGENCY_ID}`, load);

  const create = async () => {
    if (busy) return;
    setBusy(true);
    const { data, error } = await supabase.rpc("rpg_session_new", { p_name: name });
    setBusy(false);
    if (error) { onError(error.message); return; }
    setName("");
    nudge();
    if (data) onOpen(data);
  };

  return (
    <div>
      {isParent && (
        <div style={{ ...card, display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center", marginBottom: 12 }}>
          <input style={{ ...input, flex: "1 1 200px" }} placeholder="Name the fight, or leave it blank" value={name}
            onChange={e => setName(e.target.value)} onKeyDown={e => { if (e.key === "Enter") create(); }} />
          <button type="button" style={btn("primary")} onClick={create} disabled={busy}>{busy ? "Starting…" : "New fight"}</button>
        </div>
      )}
      {rows === null ? <div style={{ fontSize: 13, color: T.slate500 }}>Loading…</div>
        : rows.length === 0 ? (
          <div style={{ ...card, fontSize: 13, color: T.slate600 }}>
            {isParent ? "No fights yet. Start one above, add the characters and a creature, then start the fight." : "No fights yet. The game master starts one."}
          </div>
        ) : (
          <div style={{ display: "grid", gap: 8 }}>
            {rows.map(r => (
              <TabLink key={r.id} href={hrefFor(r.id)} onSelect={() => onOpen(r.id)}
                style={{ ...card, display: "block", textDecoration: "none", color: "inherit", opacity: r.status === "ended" ? 0.7 : 1 }}>
                <div style={{ display: "flex", justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
                  <span style={{ fontWeight: 700, color: T.slate900 }}>{r.name}</span>
                  <span style={{ fontSize: 12, fontWeight: 600, color: r.status === "active" ? T.green : T.slate500 }}>{fightStatus(r)}</span>
                </div>
                {r.who && <div style={{ fontSize: 12, color: T.slate600, marginTop: 4 }}>{r.who}</div>}
              </TabLink>
            ))}
          </div>
        )}
    </div>
  );
}

// The outcome word the log leads with (rpg_outcome) and the color it wears.
const OUTCOME_COLOR = { fail: T.red, miss: T.red, wild_miss: T.red, weak_hit: T.amber, hit: T.green, success: T.green, big_hit: T.green, critical: T.gold, info: T.slate900 };
const outcomeColor = (k) => OUTCOME_COLOR[k] || T.slate900;
const outcomeWeight = (k) => (k === "big_hit" || k === "critical" || k === "wild_miss" ? 800 : 700);
// "Big hit for 28: Bramblemaw's Claw at Karen…" → the outcome up to the first colon, then the rest.
const splitOutcome = (text) => { const s = String(text || ""); const i = s.indexOf(": "); return i > 0 && i < 40 ? [s.slice(0, i), s.slice(i + 1)] : ["", s]; };
function OutcomeLine({ text, outcome, weight = 400, color = T.slate700 }) {
  const key = outcome || "info";
  const [head, rest] = key === "info" ? ["", text] : splitOutcome(text);
  return (
    <div style={{ fontSize: 13, color, fontWeight: weight }}>
      {head && <span style={{ color: outcomeColor(key), fontWeight: outcomeWeight(key) }}>{head}:</span>}{rest}
    </div>
  );
}

// A die rolled by hand. Blank means the site rolls.
const dieValue = (v) => { const n = Math.round(Number(v)); return v !== "" && n >= 1 && n <= 100 ? n : null; };
function DieBox({ value, onChange }) {
  return (
    <div>
      <div style={{ fontSize: 11, color: T.slate500, fontWeight: 700 }}>Your die</div>
      <input style={{ ...input, width: 78, textAlign: "center", marginTop: 4 }} inputMode="numeric" placeholder="1 to 100" value={value}
        onChange={e => onChange(e.target.value.replace(/[^0-9]/g, "").slice(0, 3))} />
    </div>
  );
}
const cannotActWhy = (p) => (isDown(p) ? "is down" : (p.effects || []).find(e => e.cannot_act) ? `is ${(p.effects || []).find(e => e.cannot_act).name}` : "cannot act");

function FightView({ id, isParent, defs, onBack, backHref, onError }) {
  const [st, setSt] = useState(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  const [last, setLast] = useState(null);
  const [adding, setAdding] = useState(false);
  const [openRow, setOpenRow] = useState(null);

  const pull = useCallback(async () => {
    const { data, error } = await supabase.rpc("rpg_session_state", { p_session_id: id });
    if (error) { onError(error.message); return; }
    setSt(data || null);
  }, [id, onError]);
  useEffect(() => { pull(); }, [pull]);
  const nudge = useLiveChannel(`rpg_fight:${id}`, pull);

  const s = st?.session || {};
  const parts = Array.isArray(st?.participants) ? st.participants : [];
  const events = Array.isArray(st?.events) ? st.events : [];
  const current = parts.find(p => p.is_current) || null;

  const run = useCallback(async (fn, args, showFor = null) => {
    if (busy) return null;
    setBusy(true); setMsg(null);
    const { data, error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) { setMsg(error.message); return null; }
    if (showFor) setLast({ actorId: showFor, results: Array.isArray(data?.results) ? data.results : [] });
    await pull();
    nudge();
    return data ?? true;
  }, [busy, pull, nudge]);

  if (!st) return <div style={{ fontSize: 13, color: T.slate500 }}>Loading…</div>;

  const ended = s.status === "ended";
  const active = s.status === "active";
  const setup = s.status === "setup";
  // The one whose turn it is acts. Players act for a character on its turn; the game master acts for anyone on theirs.
  const actor = current && active && (isParent || current.kind === "character") ? current : null;
  const endTurn = () => run("rpg_session_next_turn", { p_session_id: id });
  const del = async () => {
    if (!window.confirm(`Delete ${s.name} and everything in its log?`)) return;
    const { error } = await supabase.from("rpg_sessions").delete().eq("id", id);
    if (error) { setMsg(error.message); return; }
    onBack();
  };
  const lastFor = (p) => (last && last.actorId === p.id && last.results.length > 0 ? last.results : null);

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ display: "flex", alignItems: "center", flexWrap: "wrap", gap: 8 }}>
        <TabLink href={backHref} onSelect={onBack} style={btn("soft", true)}>‹ All fights</TabLink>
        <div style={{ fontSize: 18, fontWeight: 700, color: T.slate900, minWidth: 0, flex: "1 1 auto" }}>{s.name}{ended ? " · over" : ""}</div>
        {isParent && !ended && (
          <button type="button" style={btn(adding || setup ? "primary" : "soft", true)} onClick={() => setAdding(!adding)}>{adding || setup ? "Adding" : "Add someone"}</button>
        )}
        {isParent && setup && (
          <button type="button" style={btn("primary", true)} disabled={busy || parts.length === 0} onClick={endTurn}>Start the fight</button>
        )}
        {isParent && !ended && (
          <button type="button" style={btn("soft", true)} disabled={busy}
            onClick={() => { if (window.confirm("End this fight? Nothing more can happen in it.")) run("rpg_session_end", { p_session_id: id }); }}>End fight</button>
        )}
        {isParent && ended && <button type="button" style={btn("danger", true)} onClick={del}>Delete fight</button>}
      </div>

      {msg && <div style={{ ...card, borderColor: T.red, color: T.red, fontSize: 13 }}>{msg}</div>}

      {isParent && !ended && (adding || setup) && <AddToFight st={st} id={id} busy={busy} run={run} startOpen />}

      <div style={card}>
        {parts.length === 0 && <div style={{ fontSize: 13, color: T.slate500 }}>No one is in this fight yet.</div>}
        {parts.map((p, i) => (
          <ParticipantRow key={p.id} p={p} i={i} isParent={isParent} ended={ended} busy={busy}
            open={openRow === p.id} onToggle={() => setOpenRow(openRow === p.id ? null : p.id)} run={run}>
            {actor && actor.id === p.id && p.kind === "character" && (
              <CharacterActions key={p.id} actor={p} parts={parts} s={s} busy={busy} run={run} onEnd={endTurn} last={lastFor(p)} />
            )}
            {actor && actor.id === p.id && p.kind === "creature" && (
              <CreatureActions key={p.id} actor={p} parts={parts} defs={defs} sessionId={id} busy={busy} run={run} onEnd={endTurn} last={lastFor(p)} />
            )}
          </ParticipantRow>
        ))}
      </div>

      <FightLog events={events} />
    </div>
  );
}
function AddToFight({ st, id, busy, run, startOpen }) {
  const [open, setOpen] = useState(startOpen);
  const [creature, setCreature] = useState("");
  const chars = Array.isArray(st?.available?.characters) ? st.available.characters : [];
  const creatures = Array.isArray(st?.available?.creatures) ? st.available.creatures : [];
  const pick = creatures.some(c => c.id === creature) ? creature : (creatures[0]?.id || "");
  if (chars.length === 0 && creatures.length === 0) return null;
  if (!open && !startOpen) {
    return <div><button type="button" style={btn("soft", true)} onClick={() => setOpen(true)}>Add someone to the fight</button></div>;
  }
  return (
    <div style={{ ...card, display: "grid", gap: 8 }}>
      <div style={label}>Add to the fight</div>
      {chars.length > 0 && (
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          {chars.map(c => (
            <button key={c.id} type="button" style={btn("soft", true)} disabled={busy}
              onClick={() => run("rpg_session_add", { p_session_id: id, p_character_id: c.id })}>+ {c.name}</button>
          ))}
        </div>
      )}
      {creatures.length > 0 && (
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap", alignItems: "center" }}>
          <select style={input} value={pick} onChange={e => setCreature(e.target.value)}>
            {creatures.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
          <button type="button" style={btn("soft", true)} disabled={busy || !pick}
            onClick={() => run("rpg_session_add", { p_session_id: id, p_creature_id: pick })}>Add creature</button>
        </div>
      )}
      {!startOpen && <div><button type="button" style={btn("soft", true)} onClick={() => setOpen(false)}>Done adding</button></div>}
    </div>
  );
}

// One line per fighter: name, health bar (the number only for the game master), what is on them; the column on
// the right holds their moves, and only while it is their turn.
function ParticipantRow({ p, i, isParent, ended, busy, open, onToggle, run, children }) {
  const [amount, setAmount] = useState("5");
  const down = isDown(p);
  const hasNums = p.vitality_left != null && p.vitality_max != null;
  const share = hasNums ? (Number(p.vitality_max) > 0 ? Number(p.vitality_left) / Number(p.vitality_max) : 0) : (Number(p.vitality_share) || 0);
  const amt = Math.round(Number(amount) || 0);
  const effects = Array.isArray(p.effects) ? p.effects : [];
  return (
    <div style={{ borderTop: i ? `1px solid ${T.slate100}` : "none", padding: "10px 0", display: "flex", gap: 14, flexWrap: "wrap", alignItems: "flex-start" }}>
      <div style={{ flex: "1 1 240px", minWidth: 0 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
          <span style={{ width: 10, height: 10, borderRadius: 5, background: p.color || T.slate400, flexShrink: 0 }} />
          <span style={{ fontWeight: p.is_current ? 800 : 600, color: T.slate900 }}>{p.name}</span>
          {down ? <span style={pill(T.red, T.redLt)}>Down</span> : (
            <>
              <div style={{ flex: "0 1 140px", minWidth: 60, height: 8, background: T.slate100, borderRadius: 4, overflow: "hidden" }}>
                <div style={{ width: `${Math.max(0, Math.min(1, share)) * 100}%`, height: "100%", background: share > 0.5 ? T.green : share > 0.2 ? T.amber : T.red }} />
              </div>
              {isParent && hasNums && <span style={{ fontSize: 12, color: T.slate600, whiteSpace: "nowrap" }}>{p.vitality_left} of {p.vitality_max}</span>}
            </>
          )}
          {effects.map(e => <span key={e.name} style={pill(T.amber, T.amberLt)} title={e.source ? `From ${e.source}` : undefined}>{e.name}</span>)}
          {isParent && !ended && (
            <button type="button" onClick={onToggle} title="Damage, heal, or take out"
              style={{ background: "none", border: "none", color: T.slate400, cursor: "pointer", fontSize: 16, lineHeight: 1, padding: "0 4px" }}>…</button>
          )}
        </div>
        {open && (
          <div style={{ display: "flex", gap: 6, alignItems: "center", flexWrap: "wrap", marginTop: 8 }}>
            <input style={{ ...input, width: 64, textAlign: "center" }} inputMode="numeric" value={amount} onChange={e => setAmount(e.target.value)} />
            <button type="button" style={btn("soft", true)} disabled={busy || amt <= 0}
              onClick={() => run("rpg_session_adjust_vitality", { p_participant_id: p.id, p_delta: amt })}>Damage</button>
            <button type="button" style={btn("soft", true)} disabled={busy || amt <= 0}
              onClick={() => run("rpg_session_adjust_vitality", { p_participant_id: p.id, p_delta: -amt })}>Heal</button>
            <button type="button" style={btn("danger", true)} disabled={busy}
              onClick={() => { if (window.confirm(`Take ${p.name} out of the fight?`)) run("rpg_session_remove", { p_participant_id: p.id }); }}>Take out</button>
          </div>
        )}
      </div>
      {children && <div style={{ flex: "1 1 280px", minWidth: 0 }}>{children}</div>}
    </div>
  );
}

// A character's turn. Any check a rule put on them comes first (Frightened → Courage against 8), then one attack;
// after the attack the controls give way to what happened. Every roll takes a die rolled by hand, or blank for the site's.
function CharacterActions({ actor, parts, s, busy, run, onEnd, last }) {
  const weapons = Array.isArray(actor.weapons) ? actor.weapons : [];
  const targets = parts.filter(p => p.id !== actor.id);
  const [weapon, setWeapon] = useState("");
  const [target, setTarget] = useState("");
  const [die, setDie] = useState("");
  const [extraDie, setExtraDie] = useState("");
  const w = weapons.some(x => x.key === weapon) ? weapon : (weapons[0]?.key || "");
  const fallback = (targets.find(p => p.kind === "creature" && !isDown(p)) || targets[0])?.id || "";
  const t = targets.some(x => x.id === target) ? target : fallback;
  const used = Number(s.turn_attacks) || 0;
  const perTurn = Number(s.attacks_per_turn) || 1;
  const check = actor.pending_check || null;
  const pendingExtra = Array.isArray(last) ? last.find(r => r.extra_pending) : null;
  const dv = dieValue(die); const badDie = die !== "" && dv == null;
  const xv = dieValue(extraDie);
  const cannot = !actor.can_act_now;
  const act = async (args) => { const r = await run("rpg_act", args, actor.id); if (r) setDie(""); };
  const extra = async () => { const r = await run("rpg_act_extra", { p_roll_id: pendingExtra.roll_id, p_roll: xv }, actor.id); if (r) setExtraDie(""); };
  const small = { fontSize: 11, color: T.slate500, fontWeight: 700 };
  return (
    <div style={{ display: "grid", gap: 8 }}>
      {cannot && !check && <div style={{ fontSize: 13, color: T.slate600 }}>{actor.name} {cannotActWhy(actor)}.</div>}
      {pendingExtra ? (
        <div style={{ display: "flex", gap: 8, alignItems: "flex-end", flexWrap: "wrap" }}>
          <div style={{ fontSize: 13, color: T.gold, fontWeight: 800, flex: "1 1 100%" }}>Critical! Roll again and enter it.</div>
          <DieBox value={extraDie} onChange={setExtraDie} />
          <button type="button" style={btn("primary")} disabled={busy || xv == null} onClick={extra}>Enter the extra roll</button>
        </div>
      ) : check ? (
        <div style={{ display: "flex", gap: 8, alignItems: "flex-end", flexWrap: "wrap" }}>
          <div style={{ fontSize: 13, color: T.slate800, flex: "1 1 100%" }}>
            Shake off <b>{check.name}</b>: {check.stat_name} {num(check.skill)} against {num(check.difficulty)}, needs {Math.ceil(Number(check.needed))} or more.
          </div>
          <DieBox value={die} onChange={setDie} />
          <button type="button" style={btn("primary")} disabled={busy || badDie}
            onClick={() => act({ p_actor_id: actor.id, p_effect: check.name, p_roll: dv })}>Roll {check.stat_name}</button>
        </div>
      ) : !cannot && used < perTurn ? (
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
          <div>
            <div style={small}>Weapon</div>
            <select style={{ ...input, marginTop: 4 }} value={w} onChange={e => setWeapon(e.target.value)}>
              {weapons.map(x => <option key={x.key} value={x.key}>{x.name} {num(x.value)}</option>)}
            </select>
          </div>
          <div>
            <div style={small}>At</div>
            <select style={{ ...input, marginTop: 4 }} value={t} onChange={e => setTarget(e.target.value)}>
              {targets.map(x => <option key={x.id} value={x.id}>{x.name}</option>)}
            </select>
          </div>
          <DieBox value={die} onChange={setDie} />
          <button type="button" style={btn("primary")} disabled={busy || !w || !t || badDie}
            onClick={() => act({ p_actor_id: actor.id, p_target_ids: [t], p_stat_key: w, p_roll: dv })}>Attack</button>
        </div>
      ) : null}
      {Array.isArray(last) && last.length > 0 && <ResultCard results={last} />}
      <div><button type="button" style={btn("soft", true)} disabled={busy} onClick={onEnd}>End turn</button></div>
    </div>
  );
}

// A creature's turn. The site plays it by default; the game master can roll it by hand instead.
function CreatureActions({ actor, parts, defs, sessionId, busy, run, onEnd, last }) {
  const [manual, setManual] = useState(false);
  const cannot = !actor.can_act_now;
  return (
    <div style={{ display: "grid", gap: 8 }}>
      {cannot ? (
        <div style={{ fontSize: 13, color: T.slate600 }}>{actor.name} {cannotActWhy(actor)}.</div>
      ) : !manual ? (
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <button type="button" style={btn("primary")} disabled={busy} onClick={() => run("rpg_session_auto_turn", { p_session_id: sessionId }, actor.id)}>Play its turn</button>
          <button type="button" style={btn("soft")} disabled={busy} onClick={() => setManual(true)}>Roll it myself</button>
        </div>
      ) : (
        <ManualCreatureTurn actor={actor} parts={parts} defs={defs} busy={busy} run={run} />
      )}
      {Array.isArray(last) && last.length > 0 && <ResultCard results={last} />}
      {(manual || cannot) && <div><button type="button" style={btn("soft", true)} disabled={busy} onClick={onEnd}>End turn</button></div>}
    </div>
  );
}

// The creature's card as buttons: pick who it aims at, then one row per action with what it rolls.
function ManualCreatureTurn({ actor, parts, defs, busy, run }) {
  const kinds = ["action", "bonus_action", "reaction", "lair"];
  const actions = (Array.isArray(actor.actions) ? actor.actions : []).filter(a => kinds.includes(a.kind) && a.usable !== false);
  const others = parts.filter(p => p.id !== actor.id);
  const sk = actor.skills || {};
  const [picked, setPicked] = useState([]);
  const [skill, setSkill] = useState("strength");
  const [against, setAgainst] = useState("ST");
  const targetIds = picked.filter(x => others.some(o => o.id === x));
  const toggle = (pid) => setPicked(targetIds.includes(pid) ? targetIds.filter(x => x !== pid) : [...targetIds, pid]);
  const againstOpts = (Array.isArray(defs) ? defs : []).filter(d => d.grp === "physical" || d.grp === "ability");
  const act = async (args) => { const r = await run("rpg_act", args, actor.id); if (r) setPicked([]); };
  const describe = (a) => (a.skill == null ? "no roll" : `${num(a.skill)} against ${a.against_name || a.against}${a.deals_damage ? ", does damage" : ""}${a.effect ? ` → ${a.effect}` : ""}`);
  return (
    <div style={{ display: "grid", gap: 10 }}>
      <div>
        <div style={{ fontSize: 11, color: T.slate500, fontWeight: 700 }}>Aim at</div>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginTop: 4 }}>
          {others.map(o => (
            <button key={o.id} type="button" style={btn(targetIds.includes(o.id) ? "primary" : "soft", true)} onClick={() => toggle(o.id)}>{o.name}{isDown(o) ? " (down)" : ""}</button>
          ))}
        </div>
      </div>
      {ACTION_GROUPS.filter(([k]) => kinds.includes(k)).map(([kind, title]) => {
        const list = actions.filter(a => a.kind === kind);
        if (list.length === 0) return null;
        return (
          <div key={kind}>
            <div style={label}>{title}</div>
            {list.map(a => {
              const rolls = a.skill != null;
              return (
                <div key={a.id} style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap", padding: "6px 0", borderTop: `1px solid ${T.slate100}` }}>
                  <div style={{ flex: "1 1 160px", minWidth: 0 }}>
                    <div style={{ fontWeight: 600, color: T.slate900 }}>{a.name}</div>
                    <div style={{ fontSize: 12, color: T.slate600 }}>{describe(a)}</div>
                  </div>
                  {a.ready === false ? (
                    <span style={{ fontSize: 12, fontWeight: 600, color: T.amber }}>Back in {a.back_in} {Number(a.back_in) === 1 ? "turn" : "turns"}</span>
                  ) : (
                    <button type="button" style={btn("primary", true)} disabled={busy || (rolls && targetIds.length === 0)}
                      onClick={() => act(rolls ? { p_actor_id: actor.id, p_target_ids: targetIds, p_action_id: a.id } : { p_actor_id: actor.id, p_action_id: a.id })}>
                      {rolls ? "Roll" : "Use"}
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        );
      })}
      <div>
        <div style={label}>Roll one of its skills</div>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap", alignItems: "center", marginTop: 4 }}>
          <select style={input} value={skill} onChange={e => setSkill(e.target.value)}>
            {CREATURE_SKILLS.filter(([k]) => sk[k] != null).map(([k, n]) => <option key={k} value={k}>{n} {sk[k]}</option>)}
          </select>
          <span style={{ fontSize: 13, color: T.slate600 }}>against their</span>
          <select style={input} value={against} onChange={e => setAgainst(e.target.value)}>
            {againstOpts.map(d => <option key={d.key} value={d.key}>{d.name}</option>)}
          </select>
          <button type="button" style={btn("primary", true)} disabled={busy || targetIds.length === 0}
            onClick={() => act({ p_actor_id: actor.id, p_target_ids: targetIds, p_stat_key: skill, p_against: against })}>Roll</button>
        </div>
      </div>
    </div>
  );
}

function ResultCard({ results }) {
  return (
    <div style={{ display: "grid", gap: 6 }}>
      {results.map((r, i) => {
        const key = r.outcome || (r.result === "C" ? "critical" : r.result ? "success" : "fail");
        return (
          <div key={i} style={{ display: "flex", gap: 12, alignItems: "center" }}>
            <div style={{ fontSize: 30, fontWeight: 800, color: outcomeColor(key), minWidth: 50, textAlign: "center" }}>{r.roll}</div>
            <OutcomeLine text={r.text} outcome={key} />
          </div>
        );
      })}
    </div>
  );
}

function FightLog({ events }) {
  const [all, setAll] = useState(false);
  if (events.length === 0) return null;
  const shown = all ? events : events.slice(0, 14);
  return (
    <div style={card}>
      <div style={label}>What happened</div>
      <div style={{ display: "grid", gap: 4, marginTop: 6 }}>
        {shown.map(e => {
          const marker = ["turn", "round", "start", "end"].includes(e.kind);
          return (
            <div key={e.id} style={{ paddingTop: marker ? 4 : 0 }}>
              <OutcomeLine text={e.text} outcome={marker ? "info" : (e.outcome || "info")} weight={marker ? 700 : 400} color={marker ? T.slate900 : T.slate700} />
            </div>
          );
        })}
      </div>
      {events.length > 14 && (
        <button type="button" style={{ ...btn("soft", true), marginTop: 8 }} onClick={() => setAll(!all)}>{all ? "Show less" : "Show all"}</button>
      )}
    </div>
  );
}
