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
// Step 3: Creatures tab — creature cards (Bramblemaw first). Parents see the whole card: how a
// creature is made from it and what each action rolls from the creature's own sheet; players see
// a creature's names, haunts and lore once a parent taps Show to players.
// Step 4: Rules tab — the manual text verbatim (rpg_rules), every formula spelled out the
// same way the sheet does it, a needed-roll calculator, and the level-cost table.
// Step 5: Play tab, fights. The game master sets up a fight, everyone takes turns by
// Agility, players attack and roll checks on their character's turn, the game master rolls the
// creatures' card actions, and every screen follows along live. Step 6: the fight board, where everyone
// stands, moving by beats across squares with movement penalties, and a reach in squares for every roll.
// Every number comes from the database, one saved function per job:
//   rpg_character_list()                     the character cards
//   rpg_sheet(id, difficulty)                every stat, what a roll needs at that difficulty
//   rpg_new_character(name, kid, is_npc, card)   makes a character from a card (Human when none is named);
//                                            the server rolls it from the card's blueprint
//   rpg_reroll_character(id)                 fresh strengths (household: only before the first roll)
//   rpg_adjust_trait(id, key, delta)         an event moves a trait (parents): a Spirit pair's growth pulls its other side
//                                            down as much and cannot pass the root (Connection with God / Fascination with Evil)
//   rpg_roll(id, stat, difficulty, label)    one d100 roll: result, skill points, level-ups
//   rpg_roll_extra(roll_id)                  the additional roll a critical prompts (can chain)
//   rpg_adjust_vitality(id, delta)           damage taken (+) or healed (−)
//   rpg_recent_rolls(id)                     the roll log
//   rpg_creature_list()                      the creature cards (players: shown ones only)
//   rpg_creature_card(id)                    one card, built only from its record; players get names, haunts and lore
//                                            only. The game master also gets how one is made (template) and each
//                                            action's line (rpg_action_text, the same line the fight screen shows)
//   rpg_rules_page()                         the Rules tab in one read: rules, formulas, level costs
//   rpg_needed(skill, difficulty)            what a roll needs; the calculator asks the same function a roll does
//   rpg_difficulty(skill, can_act)           the difficulty a defender presents: their skill × 2 when they can act (skill and will)
//   rpg_session_list() / rpg_session_state(id)   the fights, and one fight in one read (players: creatures without numbers)
//   rpg_session_new / rpg_session_add      set up a fight; a creature is made fresh from its card; the fight clock sets who goes when
//   rpg_session_next_turn(id)                starts the fight or ends a turn on the fight clock: the turn's ticks (moving
//                                            and acting: the bigger plus half the smaller) go on the one who took it and
//                                            whoever is next on the clock goes; a round is 20 ticks (effects clear, energy
//                                            regains); other creatures roll a die for a legendary action
//   rpg_act(actor, targets, stat, action, against, difficulty, roll, effect)   one move through rpg_roll: an attack
//                                            (land, block, hit gates; armor and shields take the blow), a card action,
//                                            REST / DEFEND, or the check a rule demands; every move costs beats and energy
//   rpg_act_extra(roll, die)                 the extra die a hand-rolled critical asked for
//   rpg_session_auto_turn(id)                the site plays a creature's turn: best ready moves by rpg_action_score
//                                            while beats and energy remain, walking toward a character when none is
//                                            in reach, then passes
//   rpg_act_square(actor, x, y, action)      a move on the board: a walk that costs ticks by the mover's Speed (a square
//                                            costs 1 + its movement penalty), or a card action aimed at a square
//                                            (Rootstep, Briar Shift)
//   rpg_place / rpg_place_start / rpg_set_square / rpg_set_board   the game master sets up the board
//   rpg_creatures.image_path                 a picture in the private rpg-images bucket (parents upload)
//   rpg_session_set_status / rpg_session_adjust_vitality / rpg_session_remove / rpg_session_end   game master changes
// A character's details, coins and items change through rpg_character_update and rpg_item_add / _set_equipped /
// _use / _delete; the kids' login cannot touch character rows directly. Only a parent deletes a character.
// Show to players is a plain update on rpg_creatures (parents only, by row rules).
// =========================================================================

const PARENT_ROLES = ["owner", "admin"];
const TABS = ["characters", "creatures", "rules", "play"];
// The game master also gets Objects: the object cards and everything made from them (rpg_object_list).
const GM_TABS = ["characters", "creatures", "objects", "rules", "play"];
const TAB_LABELS = { characters: "Characters", creatures: "Creatures", objects: "Objects", rules: "Rules", play: "Play" };
// The sheet has five sections, in this order (Peter 2026-09-28): the rolled traits in Spirit, Mind and Body, the
// numbers figured only from them in Derived, and every skill, ability and armor piece together in Skills. Each stat
// carries its section from rpg_sheet (rpg_section), so the page never sorts stats by group itself. The hidden basics
// (Swing arm, Grip, ...) are never rows; they show inside a skill's parents. A skill that is second nature
// (rpg_skill_tree: every parent second nature and its own number at its bar) is hidden the same way: never a row,
// shown inside the parents of the skills built on it, and it still rolls, counts and trains.
const SECTIONS = ["Spirit", "Mind", "Body", "Derived", "Skills"];
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

// The mix line under a calculated stat: blue Spirit from the left, amber Mind in the middle, red Body from the
// right, each share what those parts actually contribute (rpg_sheet_mix). Karen's Sword: 47 / 11 / 42.
const MIX_COLORS = { spirit: T.blue, mind: T.amber, body: T.red };
function MixLine({ mix }) {
  if (!mix) return null;
  const s = Number(mix.spirit) || 0, m = Number(mix.mind) || 0, b = Number(mix.body) || 0;
  return (
    <div title={`Spirit ${s}% · Mind ${m}% · Body ${b}%`} style={{ display: "flex", height: 4, borderRadius: 2, overflow: "hidden", margin: "3px 0", background: T.slate100 }}>
      {s > 0 && <div style={{ width: `${s}%`, background: MIX_COLORS.spirit }} />}
      {m > 0 && <div style={{ width: `${m}%`, background: MIX_COLORS.mind }} />}
      {b > 0 && <div style={{ width: `${b}%`, background: MIX_COLORS.body }} />}
    </div>
  );
}
// What a calculated stat is built from (rpg_stat_parents): the averaged parts, then the hidden basics added whole.
const SECTION_COLORS = { Spirit: T.blue, Mind: T.amber, Body: T.red };
function Parents({ stat, stats }) {
  const parents = Array.isArray(stat.parents) ? stat.parents : [];
  if (!parents.length) return null;
  const mix = stat.mix || {};
  return (
    <div style={{ marginTop: 6, fontSize: 12, color: T.slate700 }}>
      <div style={{ color: T.slate500, marginBottom: 4 }}>{stat.formula_text}{mix.spirit != null && ` · Spirit ${mix.spirit}% · Mind ${mix.mind}% · Body ${mix.body}%`}</div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: "4px 12px" }}>
        {parents.map(p => (
          <span key={`${p.plus ? "plus-" : ""}${p.key}`} style={{ color: SECTION_COLORS[p.section] || T.slate700, fontWeight: 600 }}>
            {p.plus ? "+ " : ""}{p.name} {num(p.value)}{Number(p.weight) !== 1 ? ` ×${num(p.weight)}` : ""}{p.section === "Basic" ? " · basic" : (stats || []).some(x => x.key === p.key && x.tree?.second_nature) ? " · second nature" : ""}
          </span>
        ))}
      </div>
    </div>
  );
}

export default function Roleplaying({ userRole }) {
  const isParent = PARENT_ROLES.includes(userRole);
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const tabs = isParent ? GM_TABS : TABS;
  const [tab, setTab, tabHref] = useTabParam("tab", "characters", tabs);
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
        supabase.from("rpg_stat_definitions").select("key,name,abbr,grp,kind,trainable,sort_order,spirit_discipline,energy_cost,energy_type").eq("agency_id", AGENCY_ID).order("sort_order"),
      ]);
      if (!alive) return;
      if (k.error) setErr(k.error.message);
      if (d.error) setErr(d.error.message);
      setKids(Array.isArray(k.data) ? k.data : []);
      setDefs(Array.isArray(d.data) ? d.data : []);
    })();
    return () => { alive = false; };
  }, []);

  const activeTab = tabs.includes(tab) ? tab : "characters";

  return (
    <div style={{ padding: _pad, maxWidth: 980, margin: "0 auto", boxSizing: "border-box" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 10, marginBottom: 12 }}>
        <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900 }}>Roleplaying</div>
        {tabs.length > 1 && (
          <div style={{ display: "flex", gap: 6, overflowX: "auto", whiteSpace: "nowrap" }}>
            {tabs.map(t => (
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
      {activeTab === "objects" && isParent && <ObjectsTab onError={setErr} />}
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
      {isParent && rows.length > 0 && <div style={{ fontSize: 12, color: T.slate500, marginTop: 10 }}>Open a character to re-roll it, enter an event, or remove it.</div>}
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
  const [item, setItem] = useState({ card: "", name: "", stat_key: "", bonus: "1", uses_left: "" });
  const [openGroups, setOpenGroups] = useState(() => Object.fromEntries(SECTIONS.map(g => [g, true])));
  const [busy, setBusy] = useState(false);
  const [openStat, setOpenStat] = useState(null);          // the calculated stat whose parents are open
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
    const { error } = await supabase.rpc("rpg_character_update", { p_character_id: id, p_patch: patch });
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
    const { error } = await supabase.rpc("rpg_character_update", { p_character_id: id, p_patch: {
      name: form.name.trim(), kid_id: form.kid_id && form.kid_id !== "npc" ? form.kid_id : null,
      is_npc: form.kid_id === "npc", color: form.color || T.blue, notes: form.notes || null,
    } });
    setBusy(false);
    if (error) onError(error.message);
    setEditing(false);
    load(effDiff);
  };

  // Every item is made from an Object card (rpg_item_add → rpg_new_character): it rolls its own Toughness, Strength and
  // Agility, so its life, its Integrity and its weight are its own. The card is required.
  const addItem = async () => {
    if (!item.name.trim() || !item.card || busy) return;
    setBusy(true);
    const { error } = await supabase.rpc("rpg_item_add", {
      p_character_id: id, p_card: item.card, p_name: item.name.trim(), p_stat_key: item.stat_key || null,
      p_bonus: Math.round(Number(item.bonus) || 0), p_uses_left: item.uses_left === "" ? null : Math.max(0, Math.round(Number(item.uses_left) || 0)),
    });
    setBusy(false);
    if (error) onError(error.message);
    setItem({ card: "", name: "", stat_key: "", bonus: "1", uses_left: "" });
    load(effDiff);
  };
  const toggleItem = async (it) => {
    const { error } = await supabase.rpc("rpg_item_set_equipped", { p_item_id: it.id, p_equipped: !it.equipped });
    if (error) onError(error.message);
    load(effDiff);
  };
  const useItem = async (it) => {
    if (it.uses_left == null || it.uses_left <= 0) return;
    const { error } = await supabase.rpc("rpg_item_use", { p_item_id: it.id });
    if (error) onError(error.message);
    load(effDiff);
  };
  // The shop at the table: the game master repairs an item in full, 1 silver a point of life, from the owner's coins (rpg_item_repair).
  const repairItem = async (it) => {
    const { error } = await supabase.rpc("rpg_item_repair", { p_item_id: it.id });
    if (error) onError(error.message);
    load(effDiff);
  };
  const deleteItem = async (it) => {
    if (!window.confirm(`Delete ${it.name}?`)) return;
    const { error } = await supabase.rpc("rpg_item_delete", { p_item_id: it.id });
    if (error) onError(error.message);
    load(effDiff);
  };

  // The burden of sins and bad decisions: +1 or -1 by the game master (rpg_adjust_burden). It raises what Prayer and
  // Bible Study need and lowers the Boots of the Gospel of Peace evade in a fight; a successful discipline works it off.
  const adjustBurden = async (delta) => {
    const { error } = await supabase.rpc("rpg_adjust_burden", { p_character_id: id, p_delta: delta });
    if (error) onError(error.message);
    load(effDiff);
  };
  // An event at the table: +1 or -1 on a trait, on either side of a Spirit pair.
  const adjustTrait = async (key, delta) => {
    const { error } = await supabase.rpc("rpg_adjust_trait", { p_character_id: id, p_key: key, p_delta: delta });
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
          <div style={{ fontSize: 18, fontWeight: 700, color: T.slate900 }}>{sheet.name}{sheet.side === "evil" && <span style={{ ...tag("off"), marginLeft: 8, verticalAlign: "middle" }}>Evil</span>}</div>
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
          {/* The spirit side: the burden (set by the game master) and the armor of God pieces that wear, each with a life of
              3 × its value (rpg_sheet -> armor, from rpg_armor_state): the Shield of Faith blocks spiritual attacks, the
              Breastplate absorbs attacks on the heart, the Helmet attacks on the mind; Prayer or Bible Study restore them. */}
          <div style={{ display: "flex", gap: 6, marginTop: 10, alignItems: "center", flexWrap: "wrap", fontSize: 12, color: T.slate600 }}>
            <span>Burden <b style={{ color: Number(sheet.spiritual_burden) > 0 ? T.red : T.slate900 }}>{num(sheet.spiritual_burden)}</b></span>
            {isParent && <button type="button" style={btn("soft", true)} disabled={busy} title="Sins and bad decisions weigh on Prayer, Bible Study and the Boots" onClick={() => adjustBurden(1)}>+1</button>}
            {isParent && <button type="button" style={btn("soft", true)} disabled={busy || Number(sheet.spiritual_burden) <= 0} onClick={() => adjustBurden(-1)}>−1</button>}
            {(Array.isArray(sheet.armor) ? sheet.armor : []).map(a => (
              <span key={a.key} title={`Life 3 × ${a.name}; ${a.guards === "block" ? "it blocks spiritual attacks and takes the strength of each one it stops" : `it absorbs an attack on the ${a.guards} up to its value, and only what is left lands`}; Prayer or Bible Study restore it`}>
                · {a.name} <b style={{ color: a.broken ? T.red : T.slate900 }}>{num(a.left)} / {num(a.life)}</b>{a.broken ? " · broken" : ""}
              </span>
            ))}
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
                {chain.some(r => r.grew && Object.keys(r.grew).length > 0) && ` · ${chain.flatMap(r => Object.entries(r.grew || {})).map(([k, v]) => `${(defs.find(d => d.key === k) || {}).name || k} is now ${v}`).join(", ")}`}
                {chain.some(r => r.discipline && r.discipline.text) && ` · ${chain.map(r => r.discipline?.text).filter(Boolean).join(" ")}`}
              </div>
            </div>
            {last.extra_pending
              ? <button type="button" style={btn("primary")} disabled={!!rolling} onClick={rollExtra}>Critical! Roll the extra</button>
              : <button type="button" style={btn("soft", true)} onClick={() => setChain([])}>Clear</button>}
          </div>
        </div>
      )}

      {/* The sheet: Spirit, Mind, Body, Derived, Skills (each stat's section comes from rpg_sheet). A calculated stat
          carries its mix line and opens to show the parents it is built from; a rolled trait keeps its controls. */}
      {SECTIONS.map(sec => {
        const rowsOf = stats.filter(s => s.section === sec && !s.tree?.second_nature);
        if (!rowsOf.length) return null;
        const open = openGroups[sec];
        return (
          <div key={sec} style={{ ...card, marginBottom: 10, padding: 0 }}>
            <button type="button" onClick={() => setOpenGroups(o => ({ ...o, [sec]: !o[sec] }))}
              style={{ ...btn("soft"), border: "none", width: "100%", textAlign: "left", display: "flex", justifyContent: "space-between", padding: "12px 14px", background: "transparent" }}>
              <span style={{ ...label, color: T.slate700 }}>{sec}</span>
              <span style={{ fontSize: 12, color: T.slate500 }}>{open ? "hide" : `${rowsOf.length} shown`}</span>
            </button>
            {open && (
              <div style={{ display: "grid", gridTemplateColumns: `repeat(auto-fit, minmax(${sec === "Skills" ? 230 : 290}px, 1fr))`, gap: 0, borderTop: `1px solid ${T.slate100}` }}>
                {rowsOf.map(s => {
                  const calc = s.kind === "derived";
                  const isOpen = calc && openStat === s.key;
                  return (
                    <div key={s.key} style={{ padding: "8px 12px", borderBottom: `1px solid ${T.slate100}`, boxSizing: "border-box", gridColumn: isOpen ? "1 / -1" : undefined }}>
                      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                        <div style={{ minWidth: 0, flex: 1 }}>
                          {calc
                            ? <button type="button" onClick={() => setOpenStat(isOpen ? null : s.key)} title={isOpen ? "Hide what it is built from" : "See what it is built from"}
                                style={{ border: "none", background: "transparent", padding: 0, cursor: "pointer", fontFamily: "inherit", fontSize: 13, fontWeight: 600, color: T.slate900, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", maxWidth: "100%", textAlign: "left" }}>{s.name} <span style={{ color: T.slate500, fontWeight: 400 }}>{isOpen ? "▾" : "▸"}</span></button>
                            : <div style={{ fontSize: 13, fontWeight: 600, color: T.slate900, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{s.name}</div>}
                          {calc && <MixLine mix={s.mix} />}
                          <div style={{ fontSize: 11, color: T.slate500 }}>
                            {needsText(s)}
                            {s.pair_key && Number(s.evil) > 0 && ` · ${s.good_name} ${num(s.good)}, ${s.evil_name} ${num(s.evil)}`}
                            {Number(s.item_bonus) !== 0 && ` · items +${num(s.item_bonus)}`}
                            {Number(s.earned_levels) > 0 && ` · trained +${num(s.earned_levels)}`}
                            {s.trainable && Number(s.next_level_cost) > 0 && ` · ${num(s.skill_points)}/${num(s.next_level_cost)} pts`}
                            {s.bulk && Number(s.bulk.over) > 0 && <span style={{ color: T.amber }} title={`${s.bulk.item} has bulk ${num(s.bulk.bulk)}; you handle ${num(s.bulk.handling)} (its basics plus (Strength + Agility) ÷ 10). Each point over takes 1 off the skill for the swing and makes it slower.`}>{` · ${s.bulk.item}: bulk ${num(s.bulk.over)} over, rolls as ${num(Math.max(Number(s.value) - Number(s.bulk.over), 0))}`}</span>}
                          </div>
                        </div>
                        <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900, minWidth: 34, textAlign: "right" }}>{num(s.value)}</div>
                        {isParent && !calc && (
                          <select style={{ ...input, padding: "4px 6px", fontSize: 12 }} value="" title="An event moves the trait" aria-label="Event"
                            onChange={e => { const v = e.target.value; if (!v) return; const [k, d] = v.split(":"); adjustTrait(k, Number(d)); }}>
                            <option value="">Event…</option>
                            <option value={`${s.key}:1`}>+1 {s.pair_key ? s.good_name : s.name}</option>
                            <option value={`${s.key}:-1`}>−1 {s.pair_key ? s.good_name : s.name}</option>
                            {s.pair_key && <option value={`${s.pair_key}:1`}>+1 {s.evil_name}</option>}
                            {s.pair_key && <option value={`${s.pair_key}:-1`}>−1 {s.evil_name}</option>}
                          </select>
                        )}
                        <button type="button" style={btn("primary", true)} disabled={!!rolling} onClick={() => roll(s)}>{rolling === s.key ? "…" : "Roll"}</button>
                      </div>
                      {isOpen && <Parents stat={s} stats={stats} />}
                    </div>
                  );
                })}
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
                <div style={{ fontSize: 13, fontWeight: 600, color: it.broken ? T.red : T.slate900 }}>{it.name}{it.broken ? " · broken" : ""}</div>
                <div style={{ fontSize: 11, color: T.slate500 }}>
                  {it.card}{it.worn ? ", worn" : ", held"}
                  {it.weapon_name && `, swung with ${it.weapon_name}`}
                  {` · life ${num(it.life_left)}/${num(it.life)}`}
                  {Number(it.integrity) > 0 && ` · ${it.worn ? "absorbs" : "blocks"} ${num(it.integrity)}`}
                  {Number(it.weight) > 0 && ` · weight ${num(it.weight)}`}
                  {Number(it.bulk) > 0 && ` · bulk ${num(it.bulk)}`}
                </div>
                <div style={{ fontSize: 11, color: T.slate500 }}>
                  {it.stat_name ? `${Number(it.bonus) >= 0 ? "+" : ""}${it.bonus} ${it.stat_name}` : "no bonus"}
                  {it.uses_left != null && ` · ${it.uses_left} uses left`}
                  {!it.equipped && " · not equipped"}
                </div>
              </div>
              {isParent && Number(it.life_left) < Number(it.life) && <button type="button" style={btn("soft", true)} title="1 silver a point of life, from the owner's coins" onClick={() => repairItem(it)}>Repair · {num(Number(it.life) - Number(it.life_left))} silver</button>}
              {it.uses_left != null && it.uses_left > 0 && <button type="button" style={btn("soft", true)} onClick={() => useItem(it)}>Use</button>}
              <button type="button" style={btn("soft", true)} onClick={() => toggleItem(it)}>{it.equipped ? "Unequip" : "Equip"}</button>
              <button type="button" style={btn("danger", true)} onClick={() => deleteItem(it)}>✕</button>
            </div>
          ))}
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(120px, 1fr))", gap: 6, marginTop: 10 }}>
            <select style={input} value={item.card} onChange={e => setItem(i => ({ ...i, card: e.target.value }))} title="What kind of thing it is: its card rolls its Toughness and sets its weight">
              <option value="">What is it?</option>
              {(sheet.object_cards || []).map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
            <input style={{ ...input, gridColumn: isPhone ? "1 / -1" : "span 2" }} placeholder="Item name" value={item.name} onChange={e => setItem(i => ({ ...i, name: e.target.value }))} />
            <select style={input} value={item.stat_key} onChange={e => setItem(i => ({ ...i, stat_key: e.target.value }))}>
              <option value="">Boosts…</option>
              {(sheet.stats || []).map(d => <option key={d.key} value={d.key}>{d.name}</option>)}
            </select>
            <input style={input} inputMode="numeric" placeholder="+" value={item.bonus} onChange={e => setItem(i => ({ ...i, bonus: e.target.value }))} title="Bonus" />
            <input style={input} inputMode="numeric" placeholder="Uses (blank = always)" value={item.uses_left} onChange={e => setItem(i => ({ ...i, uses_left: e.target.value }))} />
            <button type="button" style={btn("primary")} disabled={busy || !item.name.trim() || !item.card} onClick={addItem}>Add</button>
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
            {r.epigraph && <div style={{ fontSize: 12, color: T.slate600, fontStyle: "italic", marginTop: 6, lineHeight: 1.5 }}>{r.epigraph}</div>}
          </TabLink>
        ))}
      </div>
      {isParent && rows.length > 0 && <div style={{ fontSize: 12, color: T.slate500, marginTop: 10 }}>Players only see a creature after you open it and tap Show to players.</div>}
    </div>
  );
}

// ── Objects (game master) ────────────────────────────────────────────────────
// Every object card with how one is made from it (the same recipe chips the creature cards use), the actions it
// carries (rpg_action_text's line), and every item made from it: who holds it, life, uses (rpg_object_list, which
// reads each item through rpg_item_row, the row the sheet shows). Repair is the sheet's rpg_item_repair.
function ObjectsTab({ onError }) {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const pull = useCallback(async () => {
    const { data, error } = await supabase.rpc("rpg_object_list");
    if (error) onError(error.message);
    setRows(Array.isArray(data) ? data : []);
    setLoading(false);
  }, [onError]);
  useEffect(() => { pull(); }, [pull]);
  const repair = async (it) => {
    if (busy) return;
    setBusy(true);
    const { error } = await supabase.rpc("rpg_item_repair", { p_item_id: it.id });
    setBusy(false);
    if (error) { onError(error.message); return; }
    pull();
  };
  if (loading) return <div style={{ color: T.slate500, fontSize: 13 }}>Loading</div>;
  const chip = { fontSize: 12, color: T.slate800, background: T.slate100, border: `1px solid ${T.slate200}`, borderRadius: 999, padding: "3px 10px", boxSizing: "border-box" };
  return (
    <div>
      <div style={{ ...label, marginBottom: 10 }}>Objects</div>
      <div style={{ display: "grid", gap: 10 }}>
        {rows.map(c => {
          const entries = Array.isArray(c.template?.entries) ? c.template.entries : [];
          const actions = Array.isArray(c.actions) ? c.actions : [];
          const items = Array.isArray(c.items) ? c.items : [];
          return (
            <div key={c.id} style={{ ...card, borderLeft: `4px solid ${c.color || T.slate400}` }}>
              <div style={{ display: "flex", alignItems: "baseline", gap: 8, flexWrap: "wrap" }}>
                <div style={{ fontWeight: 700, fontSize: 15, color: T.slate900 }}>{c.name}</div>
                <span style={{ fontSize: 12, color: T.slate500 }}>{c.worn ? "worn" : "held"}{c.weapon_name ? ` · swung with ${c.weapon_name}` : ""}</span>
              </div>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginTop: 8 }}>
                {entries.map(e => <span key={e.key} style={chip}>{e.name} {chipText(e)}</span>)}
              </div>
              {actions.map(a => (
                <div key={a.id} style={{ fontSize: 12, color: T.slate600, marginTop: 6 }}><b style={{ color: T.slate800 }}>{a.name}.</b> {a.line}</div>
              ))}
              {items.length === 0
                ? <div style={{ fontSize: 12, color: T.slate500, marginTop: 8 }}>Nothing made from it yet.</div>
                : items.map(it => (
                  <div key={it.id} style={{ display: "flex", alignItems: "center", gap: 8, padding: "6px 0", borderTop: `1px solid ${T.slate100}`, marginTop: 6 }}>
                    <div style={{ flex: 1, minWidth: 0, opacity: it.equipped ? 1 : 0.5 }}>
                      <div style={{ fontSize: 13, color: it.broken ? T.red : T.slate900 }}><b>{it.name}</b> · {it.owner}{it.broken ? " · broken" : ""}</div>
                      <div style={{ fontSize: 11, color: T.slate500 }}>
                        life {num(it.life_left)}/{num(it.life)}
                        {Number(it.integrity) > 0 && ` · ${it.worn ? "absorbs" : "blocks"} ${num(it.integrity)}`}
                        {it.stat_name ? ` · ${Number(it.bonus) >= 0 ? "+" : ""}${it.bonus} ${it.stat_name}` : ""}
                        {it.uses_left != null && ` · ${it.uses_left} uses left`}
                        {!it.equipped && " · not equipped"}
                      </div>
                    </div>
                    {Number(it.life_left) < Number(it.life) && <button type="button" style={btn("soft", true)} disabled={busy} title="1 silver a point of life, from the owner's coins" onClick={() => repair(it)}>Repair · {num(Number(it.life) - Number(it.life_left))} silver</button>}
                  </div>
                ))}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// A picture for the card. Pictures live in the private rpg-images bucket: everyone signed in can
// see them, parents upload. No picture yet → a parent gets an upload control and a ready-made
// prompt to paste into ChatGPT; players just see the empty frame.
const plainText = (t) => String(t || "").replace(/[*_`#>]/g, "").replace(/\s+/g, " ").trim();
const imagePrompt = (c) => [
  `Illustrate ${c.name} for a family fantasy tabletop game.`,
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

// How a character made from this card is rolled (rpg_creature_card -> template): the card above it, each blueprint
// entry as a set number (a boss), a divider the trait rolls with (never under 1: ÷ 2 lands 1 to 50), and/or
// experience: skill points spent up the same level ladder a player climbs, from wherever the roll lands (from_1 and
// from_top say where those points take a roll of 1 and a roll at the top).
const pts = (n) => Number(n).toLocaleString("en-US");
const chipText = (e) => {
  if (e.fixed != null) return `${num(e.fixed)}, set`;
  const parts = [];
  if (e.divisor != null) parts.push(`÷ ${Number(e.divisor)}, lands 1 to ${num(e.top)}`);
  if (e.points != null) parts.push(`${pts(e.points)} points, lands ${num(e.from_1)} to ${num(e.from_top)}`);
  return parts.join(" · ");
};
function CardRecipe({ tmpl, entries }) {
  const chip = { fontSize: 12, color: T.slate800, background: T.slate100, border: `1px solid ${T.slate200}`, borderRadius: 999, padding: "3px 10px", boxSizing: "border-box" };
  return (
    <div style={{ ...card, marginBottom: 12 }}>
      <div style={label}>How one is made</div>
      {tmpl.parent_name && <div style={{ fontSize: 13, color: T.slate700, marginTop: 6 }}>Made from the {tmpl.parent_name} card: anything this card leaves out comes from that one.</div>}
      {entries.length > 0 && (
        <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginTop: 8 }}>
          {entries.map(e => (
            <span key={e.key} style={chip}>
              {e.name} {chipText(e)}{e.inherited && tmpl.parent_name ? ` (from ${tmpl.parent_name})` : ""}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

// The game master's half of the card, in folds: how a creature is made from it, the actions with the line
// rpg_action_text writes from each one's record, then the rumor table and the tip. Nothing here is composed by the page.
// Reading parts start shut.
function CreatureGmCard({ c, accent }) {
  const actions = Array.isArray(c.actions) ? c.actions : [];
  const ofKind = (k) => actions.filter(a => a.kind === k);
  const rumors = Array.isArray(c.rumors) ? c.rumors : [];
  const tmpl = c.template || {};
  const entries = Array.isArray(tmpl.entries) ? tmpl.entries : [];
  const group = (title, list, intro) => (list.length === 0 ? null : (
    <div style={{ marginBottom: 10 }}>
      <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, borderBottom: `2px solid ${accent}`, paddingBottom: 4 }}>{title}</div>
      {intro && <CardText text={intro} style={{ marginTop: 6 }} />}
      {list.map(a => (
        <div key={a.id} style={{ padding: "8px 0", borderTop: `1px solid ${T.slate100}` }}>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 2 }}>{a.heading || a.name}</div>
          <CardText text={a.description} />
          {a.line && <div style={{ fontSize: 12, color: T.blue, fontWeight: 600, lineHeight: 1.5, marginTop: 4 }}>{a.line}</div>}
        </div>
      ))}
    </div>
  ));

  return (
    <>
      <CardRecipe tmpl={tmpl} entries={entries} />

      {actions.length > 0 && (
      <Fold title="Actions and nature" open>
        {group("Actions", ofKind("action"))}
        {group("Bonus actions", ofKind("bonus_action"))}
        {group("Reactions", ofKind("reaction"))}
        {group(`Legendary actions (${num(c.legendary_per_round)} a round)`, ofKind("legendary"), c.legendary_intro)}
        {group(c.lair_title ? `Lair actions (${c.lair_title})` : "Lair actions", ofKind("lair"), c.lair_intro)}
        {group("Nature", ofKind("trait"))}
      </Fold>
      )}

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
  const [openGroups, setOpenGroups] = useState(() => Object.fromEntries(SECTIONS.map(g => [g, true])));
  if (!stats.length) return null;
  return (
    <div>
      <div style={{ ...label, margin: "14px 0 8px" }}>How every number on the sheet is figured</div>
      {SECTIONS.map(sec => {
        const g = sec, title = sec;
        const rowsOf = stats.filter(s => s.section === sec);
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
                          {s.card_name && <span style={{ color: T.slate500, fontSize: 11 }}> · {s.card_name} only</span>}
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
const OUTCOME_COLOR = { fail: T.red, miss: T.red, wild_miss: T.red, evaded: T.amber, blocked: T.blue, bounced: T.blue, weak_hit: T.amber, hit: T.green, success: T.green, big_hit: T.green, critical: T.gold, info: T.slate900 };
// Physical energy is red, spiritual energy blue.
const ENERGY_COLOR = { physical: T.red, spiritual: T.blue };
function EnergyBar({ kind, pool, showNumbers }) {
  if (!pool || !Number(pool.max)) return null;
  const share = Math.max(0, Math.min(1, Number(pool.left) / Number(pool.max)));
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 4 }} title={`${kind} energy`}>
      <span style={{ width: 44, height: 5, background: T.slate100, borderRadius: 3, overflow: "hidden", display: "inline-block" }}>
        <span style={{ display: "block", width: `${share * 100}%`, height: "100%", background: ENERGY_COLOR[kind] }} />
      </span>
      {showNumbers && <span style={{ fontSize: 11, color: T.slate500, whiteSpace: "nowrap" }}>{pool.left}/{pool.max}</span>}
    </span>
  );
}
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
  const [pending, setPending] = useState(null);

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

      <FightGrid st={st} isParent={isParent} actor={actor} ended={ended} busy={busy} run={run} pending={pending} onPending={setPending} />

      <div style={card}>
        {parts.length === 0 && <div style={{ fontSize: 13, color: T.slate500 }}>No one is in this fight yet.</div>}
        {parts.map((p, i) => (
          <ParticipantRow key={p.id} p={p} i={i} isParent={isParent} ended={ended} busy={busy}
            open={openRow === p.id} onToggle={() => setOpenRow(openRow === p.id ? null : p.id)} run={run}>
            {actor && actor.id === p.id && p.kind === "character" && (
              <CharacterActions key={p.id} actor={p} parts={parts} defs={defs} s={s} busy={busy} run={run} onEnd={endTurn} last={lastFor(p)} onPending={setPending} />
            )}
            {actor && actor.id === p.id && p.kind === "creature" && (
              <CreatureActions key={p.id} actor={p} parts={parts} defs={defs} s={s} sessionId={id} busy={busy} run={run} onEnd={endTurn} last={lastFor(p)} onPending={setPending} />
            )}
          </ParticipantRow>
        ))}
      </div>

      <FightLog events={events} />
    </div>
  );
}
// The fight board, built from rpg_session_state: squares shaded by their movement penalty (the number sits in the
// corner), green when forest, orange while burning (a glyph in the corner), everyone on their square. On the turn of
// someone you act for, the squares they can still reach this turn are ringed, with the ticks each costs; tap one to
// move there (rpg_act_square). A card action aimed at a square (Briar Shift, a Torch's Light the ground) waits here
// for its square. The game master places fighters, paints penalties, forest and fire (rpg_set_square) and sets the
// board's size.
function FightGrid({ st, isParent, actor, ended, busy, run, pending, onPending }) {
  const s = st?.session || {};
  const w = Number(s.grid_w) || 12;
  const h = Number(s.grid_h) || 12;
  const terrain = s.terrain && typeof s.terrain === "object" ? s.terrain : {};
  const parts = Array.isArray(st?.participants) ? st.participants : [];
  const moves = Array.isArray(st?.moves) ? st.moves : [];
  const [mode, setMode] = useState("move");
  const [who, setWho] = useState("");
  const [pen, setPen] = useState(2);
  const [brush, setBrush] = useState("penalty");
  const [size, setSize] = useState(null);
  const placed = parts.filter(p => p.pos_x != null);
  if (ended || (!isParent && placed.length === 0)) return null;
  const sq = (x, y) => `${String.fromCharCode(64 + x)}${y}`;
  const at = {};
  placed.forEach(p => { at[`${p.pos_x},${p.pos_y}`] = p; });
  const ground = (k) => (terrain[k] && typeof terrain[k] === "object" ? terrain[k] : {});
  const moveAt = {};
  if (actor && !pending && mode === "move") moves.forEach(m => { moveAt[`${m.x},${m.y}`] = m; });
  const pick = parts.some(p => p.id === who) ? who : ((parts.find(p => p.pos_x == null) || parts[0])?.id || "");
  const sw = size || { w, h };
  const click = (x, y) => {
    if (busy) return;
    if (pending) {
      run("rpg_act_square", { p_actor_id: pending.actorId, p_x: x, p_y: y, p_action_id: pending.actionId }, pending.actorId).then(r => { if (r) onPending(null); });
      return;
    }
    if (isParent && mode === "place") { if (pick) run("rpg_place", { p_participant_id: pick, p_x: x, p_y: y }); return; }
    if (isParent && mode === "ground") {
      const g = ground(`${x},${y}`);
      if (brush === "forest") run("rpg_set_square", { p_session_id: s.id, p_x: x, p_y: y, p_forest: !g.forest });
      else if (brush === "fire") run("rpg_set_square", { p_session_id: s.id, p_x: x, p_y: y, p_burning: !g.burning });
      else run("rpg_set_square", { p_session_id: s.id, p_x: x, p_y: y, p_penalty: pen });
      return;
    }
    if (moveAt[`${x},${y}`]) run("rpg_act_square", { p_actor_id: actor.id, p_x: x, p_y: y }, actor.id);
  };
  const axis = { fontSize: 10, color: T.slate500, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" };
  const cells = [<div key="corner" />];
  for (let x = 1; x <= w; x++) cells.push(<div key={`c${x}`} style={axis}>{String.fromCharCode(64 + x)}</div>);
  for (let y = 1; y <= h; y++) {
    cells.push(<div key={`r${y}`} style={axis}>{y}</div>);
    for (let x = 1; x <= w; x++) {
      const k = `${x},${y}`;
      const p = at[k];
      const m = moveAt[k];
      const g = ground(k);
      const n = Number(g.p) || 0;
      const forest = !!g.forest;
      const fire = !!g.burning;
      const title = `${sq(x, y)}${n ? ` · movement penalty ${n}` : ""}${forest ? " · forest" : ""}${fire ? ` · burning (${s.burn_cost} more to step into)` : ""}${p ? ` · ${p.name}${p.out ? ` (${p.out})` : ""}` : ""}${m ? ` · costs ${m.cost}, ${m.ticks} ticks` : ""}`;
      const live = pending || (isParent && mode !== "move") || m;
      cells.push(
        <button key={k} type="button" title={title} onClick={() => click(x, y)}
          style={{ aspectRatio: "1 / 1", minWidth: 0, padding: 0, margin: 0, position: "relative", borderRadius: 3, fontFamily: "inherit",
                   border: m ? `2px solid ${T.blue}` : `1px solid ${T.slate200}`, cursor: live ? "pointer" : "default",
                   background: fire ? `hsl(24, 90%, ${86 - n * 4}%)` : forest ? `hsl(130, 32%, ${88 - n * 5}%)` : n > 0 ? `hsl(75, 28%, ${92 - n * 6}%)` : T.slate50,
                   display: "flex", alignItems: "center", justifyContent: "center" }}>
          {n > 0 && <span style={{ position: "absolute", top: 0, left: 2, fontSize: 8, lineHeight: 1.2, color: n >= 6 ? T.white : T.slate600 }}>{n}</span>}
          {(fire || forest) && <span style={{ position: "absolute", top: 0, right: 1, fontSize: 8, lineHeight: 1.2 }}>{fire ? "🔥" : "🌲"}</span>}
          {p ? (
            <span style={{ width: "76%", height: "76%", borderRadius: "50%", background: p.color || T.slate400, opacity: p.out ? 0.35 : 1,
                           color: T.white, fontSize: 10, fontWeight: 800, display: "flex", alignItems: "center", justifyContent: "center",
                           boxShadow: p.is_current ? `0 0 0 2px ${T.slate900}` : "none" }}>{String(p.name || "?").slice(0, 1).toUpperCase()}</span>
          ) : m ? (
            <span style={{ fontSize: 9, fontWeight: 800, color: T.blue }}>{m.ticks}</span>
          ) : null}
        </button>
      );
    }
  }
  const off = parts.filter(p => p.pos_x == null);
  return (
    <div style={{ ...card, display: "grid", gap: 10 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
        <div style={label}>Board</div>
        {pending ? (
          <>
            <div style={{ fontSize: 12, color: T.slate800, fontWeight: 600 }}>Tap a square for {pending.name}.</div>
            <button type="button" style={btn("soft", true)} onClick={() => onPending(null)}>Cancel</button>
          </>
        ) : actor && mode === "move" && moves.length > 0 ? (
          <div style={{ fontSize: 12, color: T.slate600 }}>
            Tap a ringed square to move {actor.name}; the number is the ticks it takes. A turn holds {s.round_ticks} ticks of moving.
          </div>
        ) : null}
      </div>
      {isParent && (
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap", alignItems: "center" }}>
          {[["move", "Move"], ["place", "Place"], ["ground", "Ground"]].map(([k, t]) => (
            <button key={k} type="button" style={btn(mode === k ? "primary" : "soft", true)} onClick={() => setMode(k)}>{t}</button>
          ))}
          {mode === "place" && (
            <>
              <select style={input} value={pick} onChange={e => setWho(e.target.value)}>
                {parts.map(p => <option key={p.id} value={p.id}>{p.name}{p.pos_x != null ? ` · ${sq(p.pos_x, p.pos_y)}` : " · off the board"}</option>)}
              </select>
              <button type="button" style={btn("soft", true)} disabled={busy || !pick} onClick={() => run("rpg_place", { p_participant_id: pick })}>Take off the board</button>
              <button type="button" style={btn("soft", true)} disabled={busy || off.length === 0} onClick={() => run("rpg_place_start", { p_session_id: s.id })}>Place everyone</button>
            </>
          )}
          {mode === "ground" && (
            <>
              <span style={{ fontSize: 12, color: T.slate600 }}>Movement penalty</span>
              {[0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map(v => (
                <button key={v} type="button" style={{ ...btn(brush === "penalty" && pen === v ? "primary" : "soft", true), minWidth: 30 }} onClick={() => { setBrush("penalty"); setPen(v); }}>{v}</button>
              ))}
              <button type="button" style={btn(brush === "forest" ? "primary" : "soft", true)} title="Tap a square to make it forest, or plain again" onClick={() => setBrush("forest")}>🌲 Forest</button>
              <button type="button" style={btn(brush === "fire" ? "primary" : "soft", true)} title={`Tap a square to set it alight for ${s.burn_rounds} rounds, or to put it out`} onClick={() => setBrush("fire")}>🔥 Fire</button>
              <span style={{ fontSize: 12, color: T.slate600 }}>Size</span>
              <input style={{ ...input, width: 48, textAlign: "center" }} inputMode="numeric" value={sw.w} onChange={e => setSize({ ...sw, w: e.target.value })} />
              <span style={{ fontSize: 12, color: T.slate600 }}>×</span>
              <input style={{ ...input, width: 48, textAlign: "center" }} inputMode="numeric" value={sw.h} onChange={e => setSize({ ...sw, h: e.target.value })} />
              <button type="button" style={btn("soft", true)} disabled={busy || !size}
                onClick={() => run("rpg_set_board", { p_session_id: s.id, p_w: Math.round(Number(sw.w)), p_h: Math.round(Number(sw.h)) }).then(r => { if (r) setSize(null); })}>Set size</button>
            </>
          )}
        </div>
      )}
      <div style={{ display: "grid", gridTemplateColumns: `16px repeat(${w}, minmax(0, 1fr))`, gap: 1, width: "100%", maxWidth: 36 * w + 16, userSelect: "none" }}>
        {cells}
      </div>
      {isParent && off.length > 0 && (
        <div style={{ fontSize: 12, color: T.slate600 }}>Off the board, so always in reach: {off.map(p => p.name).join(", ")}.</div>
      )}
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
          {!p.is_current && !p.out && p.ticks_away != null && <span style={{ fontSize: 11, color: T.slate500, whiteSpace: "nowrap" }} title="Ticks until their turn on the fight clock">in {p.ticks_away}</span>}
          {down ? <span style={pill(T.red, T.redLt)}>{p.out || "Down"}{p.revival ? ` · rises round ${p.revival.rises_round}` : ""}</span> : (
            <>
              <div style={{ flex: "0 1 140px", minWidth: 60, height: 8, background: T.slate100, borderRadius: 4, overflow: "hidden" }}>
                <div style={{ width: `${Math.max(0, Math.min(1, share)) * 100}%`, height: "100%", background: share > 0.5 ? T.green : share > 0.2 ? T.amber : T.red }} />
              </div>
              {isParent && hasNums && <span style={{ fontSize: 12, color: T.slate600, whiteSpace: "nowrap" }}>{p.vitality_left} of {p.vitality_max}</span>}
            </>
          )}
          <EnergyBar kind="physical" pool={p.energy?.physical} showNumbers={isParent} />
          <EnergyBar kind="spiritual" pool={p.energy?.spiritual} showNumbers={isParent} />
          {effects.filter(e => e.name !== p.out).map(e => <span key={e.name} style={pill(T.amber, T.amberLt)} title={e.source ? `From ${e.source}` : undefined}>{e.name}</span>)}
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
function CharacterActions({ actor, parts, defs, s, busy, run, onEnd, last, onPending }) {
  const weapons = Array.isArray(actor.weapons) ? actor.weapons : [];
  // Actions lent by things held in the hand (rpg_session_state -> actions): a Torch's Light the ground is aimed at a square on the board.
  const itemActions = (Array.isArray(actor.actions) ? actor.actions : []).filter(a => a.square);
  // Prayer and Bible Study in a fight: the turn's action, paid from spiritual energy (rpg_act); the burden raises what they need.
  const disciplines = (Array.isArray(defs) ? defs : []).filter(d => d.spirit_discipline);
  // A creature at 0 (Dead, or Sunk under its card's revival rule) cannot be attacked; a Sunk one can only be reached
  // by the roll its card names (rpg_session_state -> revival).
  const targets = parts.filter(p => p.id !== actor.id && !p.out);
  const waiting = parts.filter(p => p.revival);
  const [weapon, setWeapon] = useState("");
  const [target, setTarget] = useState("");
  const [die, setDie] = useState("");
  const [extraDie, setExtraDie] = useState("");
  const w = weapons.some(x => x.key === weapon) ? weapon : (weapons[0]?.key || "");
  const fallback = (targets.find(p => p.kind === "creature" && !isDown(p)) || targets[0])?.id || "";
  const t = targets.some(x => x.id === target) ? target : fallback;
  const wpn = weapons.find(x => x.key === w) || {};
  const canPay = Number(actor.energy?.[wpn.energy_type || "physical"]?.left ?? 0) >= (Number(wpn.energy_cost) || 0);
  const acted = (Number(s.turn_action_ticks) || 0) > 0;
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
      ) : !cannot && !acted ? (
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
          <div>
            <div style={small}>Weapon</div>
            <select style={{ ...input, marginTop: 4 }} value={w} onChange={e => setWeapon(e.target.value)}>
              {weapons.map(x => <option key={x.key} value={x.key}>{x.name} {num(x.value)}{x.bulk && Number(x.bulk.over) > 0 ? ` (bulk ${num(x.bulk.over)} over: rolls as ${num(Math.max(Number(x.value) - Number(x.bulk.over), 0))})` : ""} · {x.ticks} ticks · {x.energy_cost} {x.energy_type}</option>)}
            </select>
          </div>
          <div>
            <div style={small}>At</div>
            <select style={{ ...input, marginTop: 4 }} value={t} onChange={e => setTarget(e.target.value)}>
              {targets.map(x => <option key={x.id} value={x.id}>{x.name}</option>)}
            </select>
          </div>
          <DieBox value={die} onChange={setDie} />
          <button type="button" style={btn("primary")} disabled={busy || !w || !t || badDie || !canPay}
            onClick={() => act({ p_actor_id: actor.id, p_target_ids: [t], p_stat_key: w, p_roll: dv })}>{canPay ? "Attack" : "Too tired"}</button>
        </div>
      ) : null}
      {!cannot && !check && !pendingExtra && !acted && waiting.map(o => (
        <div key={o.id} style={{ display: "flex", gap: 8, alignItems: "flex-end", flexWrap: "wrap" }}>
          <div style={{ fontSize: 13, color: T.slate800, flex: "1 1 100%" }}>
            {o.name} is {o.revival.name} and rises in round {o.revival.rises_round}. {o.revival.skill_name} against its {o.revival.against_name} ends it for good.
          </div>
          <DieBox value={die} onChange={setDie} />
          <button type="button" style={btn("primary")} disabled={busy || badDie}
            onClick={() => act({ p_actor_id: actor.id, p_target_ids: [o.id], p_stat_key: o.revival.skill_key, p_against: o.revival.against, p_roll: dv })}>Roll {o.revival.skill_name}</button>
        </div>
      ))}
      {!cannot && !check && !pendingExtra && !acted && (
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <button type="button" style={btn("soft", true)} disabled={busy} onClick={() => act({ p_actor_id: actor.id, p_stat_key: "REST" })}>Rest</button>
          <button type="button" style={btn("soft", true)} disabled={busy} onClick={() => act({ p_actor_id: actor.id, p_stat_key: "DEFEND" })}>Defend</button>
          {disciplines.map(d => {
            const ok = Number(actor.energy?.[d.energy_type || "spiritual"]?.left ?? 0) >= (Number(d.energy_cost) || 0);
            return (
              <button key={d.key} type="button" style={btn("soft", true)} disabled={busy || badDie || !ok}
                title={`${d.energy_cost} ${d.energy_type} energy and the turn's action; the burden raises what it needs`}
                onClick={() => act({ p_actor_id: actor.id, p_stat_key: d.key, p_roll: dv })}>{ok ? d.name : `${d.name} · too tired`}</button>
            );
          })}
          {itemActions.map(a => (
            <button key={a.id} type="button" style={btn("soft", true)} disabled={busy} title={a.line || ""}
              onClick={() => onPending({ actorId: actor.id, actionId: a.id, name: `${a.name} (${a.item})` })}>{a.name} · {a.item}</button>
          ))}
        </div>
      )}
      {Array.isArray(last) && last.length > 0 && <ResultCard results={last} />}
      <TurnCost s={s} />
      <div><button type="button" style={btn("soft", true)} disabled={busy} onClick={onEnd}>End turn</button></div>
    </div>
  );
}

// A creature's turn. The site plays it by default; the game master can roll it by hand instead.
function CreatureActions({ actor, parts, defs, s, sessionId, busy, run, onEnd, last, onPending }) {
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
        <ManualCreatureTurn actor={actor} parts={parts} defs={defs} s={s} busy={busy} run={run} onPending={onPending} />
      )}
      {Array.isArray(last) && last.length > 0 && <ResultCard results={last} />}
      {manual && <TurnCost s={s} />}
      {(manual || cannot) && <div><button type="button" style={btn("soft", true)} disabled={busy} onClick={onEnd}>End turn</button></div>}
    </div>
  );
}

// The creature's card as buttons: pick who it aims at, then one row per action with what it rolls. An action aimed at
// a square (Briar Shift) asks for its square on the board.
function ManualCreatureTurn({ actor, parts, defs, s, busy, run, onPending }) {
  const kinds = ["action", "bonus_action", "reaction", "lair"];
  // One action a turn: an action or bonus action is refused once the turn has one; lair actions are free.
  const acted = (Number(s.turn_action_ticks) || 0) > 0;
  const usesTurn = (a) => a.kind === "action" || a.kind === "bonus_action";
  const actions = (Array.isArray(actor.actions) ? actor.actions : []).filter(a => kinds.includes(a.kind));
  const others = parts.filter(p => p.id !== actor.id);
  const skills = Array.isArray(actor.skills) ? actor.skills : [];
  const [picked, setPicked] = useState([]);
  const [skill, setSkill] = useState("");
  const sk = skills.some(x => x.key === skill) ? skill : (skills[0]?.key || "");
  const [against, setAgainst] = useState("ST");
  const targetIds = picked.filter(x => others.some(o => o.id === x));
  const toggle = (pid) => setPicked(targetIds.includes(pid) ? targetIds.filter(x => x !== pid) : [...targetIds, pid]);
  const againstOpts = (Array.isArray(defs) ? defs : []).filter(d => d.grp === "physical" || d.grp === "ability");
  const act = async (args) => { const r = await run("rpg_act", args, actor.id); if (r) setPicked([]); };
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
                    <div style={{ fontSize: 12, color: T.slate600 }}>{a.line}</div>
                  </div>
                  {a.ready === false ? (
                    <span style={{ fontSize: 12, fontWeight: 600, color: T.amber }}>Too tired</span>
                  ) : usesTurn(a) && acted ? (
                    <span style={{ fontSize: 12, fontWeight: 600, color: T.slate500 }}>Already acted this turn</span>
                  ) : a.square ? (
                    <button type="button" style={btn("primary", true)} disabled={busy}
                      onClick={() => onPending({ actorId: actor.id, actionId: a.id, name: a.name })}>Pick a square</button>
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
      {!acted && (
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <button type="button" style={btn("soft", true)} disabled={busy} onClick={() => act({ p_actor_id: actor.id, p_stat_key: "REST" })}>Rest</button>
          <button type="button" style={btn("soft", true)} disabled={busy} onClick={() => act({ p_actor_id: actor.id, p_stat_key: "DEFEND" })}>Defend</button>
        </div>
      )}
      <div>
        <div style={label}>Roll one of its skills</div>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap", alignItems: "center", marginTop: 4 }}>
          <select style={input} value={sk} onChange={e => setSkill(e.target.value)}>
            <optgroup label="Its own">
              {skills.filter(x => x.own).map(x => <option key={x.key} value={x.key}>{x.name} {num(x.value)}</option>)}
            </optgroup>
            <optgroup label="Everyone's">
              {skills.filter(x => !x.own).map(x => <option key={x.key} value={x.key}>{x.name} {num(x.value)}</option>)}
            </optgroup>
          </select>
          <span style={{ fontSize: 13, color: T.slate600 }}>against their</span>
          <select style={input} value={against} onChange={e => setAgainst(e.target.value)}>
            {againstOpts.map(d => <option key={d.key} value={d.key}>{d.name}</option>)}
          </select>
          <button type="button" style={btn("primary", true)} disabled={busy || !sk || targetIds.length === 0}
            onClick={() => act({ p_actor_id: actor.id, p_target_ids: targetIds, p_stat_key: sk, p_against: against })}>Roll</button>
        </div>
      </div>
    </div>
  );
}

// What this turn costs on the fight clock so far (rpg_session_state turn_cost, from rpg_turn_cost): moving and acting
// together cost the bigger plus half the smaller. Ending a turn having done neither costs one beat of waiting.
function TurnCost({ s }) {
  const m = Number(s.turn_move_ticks) || 0;
  const a = Number(s.turn_action_ticks) || 0;
  if (!m && !a) return null;
  const parts = [m ? `moved ${m} ticks` : null, a ? `acted ${a} ticks` : null].filter(Boolean).join(", ");
  return <div style={{ fontSize: 12, color: T.slate600 }}>This turn: {parts}, so it costs {s.turn_cost} ticks on the clock.</div>;
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
