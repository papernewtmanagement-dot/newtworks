import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport, useElementWidth } from "../lib/hooks.js";
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
// World map step 1: Maps tab, game master only. The world drawn at every level, from its place cards and the map
// rolls: a fantasy map down to a district (drawn symbols, names on the land), the battle grid seen from above, the
// lists in a sidebar on the left, each grid listing the places one level down, the world drawn finest.
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
//                                            takes 5 ticks at Speed 10 plus the percent of time it adds), or a card
//                                            action aimed at a square
//                                            (Rootstep, Briar Shift)
//   rpg_place / rpg_set_square               the game master moves a fighter by hand or sets fire; the ground itself
//                                            is the world map under the fight (rpg_fight_squares)
//   rpg_map_view(level, x, y)                the Maps tab in one read: one grid of the world map, from the place
//                                            cards and fixed-seed rolls for unnamed ground (sea, open land, forest,
//                                            hills, mountains, and by climate grassy plains, pine forest, jungle,
//                                            desert, tundra, snow and ice, swamp), with the list that grid shows
//                                            (the places one level down), the lands it lies in and, for the world,
//                                            every cell of the
//                                            Continent grids to draw it fine; and the open journey (its clock in
//                                            words, whose turn, the pieces and where they stand on this grid)
//   rpg_map_place_view(place)                the same read for a place shown whole: the block of cells that holds
//                                            all of it, drawn one level finer (Westerwold on 5 by 6 world cells)
//   rpg_session_new(name, on_map) / rpg_map_walk(piece, x, y) / rpg_map_camp(piece)   a journey: the group walks
//                                            the world map on the fight clock (a tick is 1/6 of a second, 8 hours of
//                                            walking a day, then 16 of camp; nobody walks into the sea)
//   rpg_creatures.image_path                 a picture in the private rpg-images bucket (parents upload)
//   rpg_session_set_status / rpg_session_adjust_vitality / rpg_session_remove / rpg_session_end   game master changes
// A character's details, coins and items change through rpg_character_update and rpg_item_add / _set_equipped /
// _use / _delete; the kids' login cannot touch character rows directly. Only a parent deletes a character.
// Show to players is a plain update on rpg_creatures (parents only, by row rules).
// =========================================================================

const PARENT_ROLES = ["owner", "admin"];
const TABS = ["characters", "creatures", "rules", "play", "maps"];
// The game master also gets Objects: the object cards and everything made from them (rpg_object_list). Maps (the
// world drawn at every level, rpg_map_view) is for everyone: the kids login sees what the group has found.
const GM_TABS = ["characters", "creatures", "objects", "rules", "play", "maps"];
const TAB_LABELS = { characters: "Characters", creatures: "Creatures", objects: "Objects", rules: "Rules", play: "Play", maps: "Maps" };
// The sheet has five sections, in this order (Peter 2026-09-28): the rolled traits in Spirit, Mind and Body, the
// numbers figured only from them in Derived, and every skill, ability and armor piece together in Skills. Each stat
// carries its section from rpg_sheet (rpg_section), so the page never sorts stats by group itself. The hidden basics
// (Swing arm, Grip, ...) are never rows; they show inside a skill's parents. A skill that is second nature
// (rpg_skill_tree: every parent second nature and its own number at its bar) is hidden the same way: never a row,
// shown inside the parents of the skills built on it, and it still rolls, counts and trains. Knowledge rows (Knowing
// Bramblemaw, one per card) have their own section; rpg_sheet decides which of them a kid sees, so the page just lists them.
const SECTIONS = ["Spirit", "Mind", "Body", "Derived", "Skills", "Knowledge"];
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
    <div style={{ padding: _pad, maxWidth: activeTab === "maps" ? "none" : 980, margin: "0 auto", boxSizing: "border-box" }}>
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
        ? <FightView id={fightId} isParent={isParent} defs={defs} onBack={() => setFightId(null)} backHref={fightHref(null)} onError={setErr}
            onMap={() => { setFightId(null); setTab("maps"); }} />
        : <FightList isParent={isParent} onOpen={setFightId} hrefFor={fightHref} onError={setErr} />)}
      {activeTab === "maps" && <MapsTab isParent={isParent} onError={setErr} onFight={(f) => { setTab("play"); setFightId(f); }} />}
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

// ── Maps (game master only) ─────────────────────────────────────────────────
// The world map, drawn at every level (rpg_map_view): seven nested grids from an Earth-size world down to a battle
// grid. Ground comes from the place cards (Old Forest, Haven, ...) and, where no place is, from fixed-seed rolls
// (land and sea, then forest, hills and mountains, then the climate of the spot: snow and ice and tundra toward the
// poles, pine forest in the cold, desert, grassy plains, jungle and swamp by how wet it is); nothing is stored per
// square. The function sends every cell,
// name, size, symbol name and link, and the page only draws them. A cell opens the grid inside it; the open grid
// lives in the URL (map=level-x-y, none = the world). A place opens where its link says: the grid inside one cell
// when it fits in one, else the place shown whole (map=p-<its id>, rpg_map_place_view: Westerwold on the 5 by 6
// world cells that hold it). The lists sit in a sidebar on the left (under the map when the tab is narrow) and the
// map takes the rest of the screen. Each grid lists the places one level down (v.list: the world lists continents,
// a continent countries, a country regions, and so on). The world and a place shown whole are drawn as fine as the
// grids inside them (v.detail: every cell of the grid one level down), so the world is the largest map.
// The drawing has two styles (MAP_ART). From the world down to a district it is a fantasy map: an inked coast,
// little trees, hills and peaks, and names written on the land. The battle grid is seen from above: grass, tree
// trunks under their crowns, rocks, water, the roofs of houses (mapRoofs), the planks of a bridge and the stones of a
// ford (step 11). Every ground has one color at every level: the fantasy map paints it in
// the color the battle grid gives it, lightened toward the paper (mapWash), so open land is grassland on every grid
// and never bare paper. The drawing is decoration only; what a cell is, and what it costs to enter, comes from the
// function. The same cell always draws the same way (mapRand).
const MAP_MOVES = [["west", "←"], ["north", "↑"], ["south", "↓"], ["east", "→"]];
// The sidebar is 280 wide and sits beside the map once the tab itself is 760 across.
const MAP_SIDE = 280;
const MAP_WIDE = 760;
const MAP_INK = "#4B3B2A";
const MAP_SERIF = "Georgia, 'Times New Roman', serif";
// The paper of the fantasy map: the sea, and the bare paper (land) that shows behind names and symbol pads.
const MAP_PAPER = { sea: "#B4CACB", shallow: "#C6D9D6", shore: "#D6E4DD", land: "#EFE5C8" };
// The kinds of unnamed ground, in the order the key lists them, each with its letter in a grid drawn fine (v.detail;
// the same letters as rpg_map_grounds).
const MAP_GROUNDS = [["sea", "~"], ["land", "."], ["plains", "g"], ["forest", "t"], ["pine", "p"], ["jungle", "j"], ["hills", "h"], ["mountains", "m"], ["desert", "d"], ["tundra", "u"], ["ice", "i"], ["swamp", "s"], ["town", "n"], ["road", "r"], ["pass", "a"], ["water", "w"], ["deep", "k"]];
// Rivers drawn as lines on a grid too coarse to hold them as water (rpg_map_view: cells' river, detail.rivers): the
// line's width in screen pixels by its size, 2 a great river down to 5 a brook.
const MAP_RIVER_W = { 2: 4.6, 3: 3.3, 4: 2.2, 5: 1.4 };
const MAP_RIVER = "#5E93AB";
// How much of a ground's battle-grid color the fantasy map takes; the rest is paper.
const MAP_TINT = 0.42;
// The ground the group has not found yet (the kids login): dark, with specks of light, like nothing else on the map.
const MAP_FOG = { dark: "#1F2029", speck: "#EDE6D3", line: "#FFFFFF" };
// A village, town or city marked on a grid (rpg_map_view: towns; step 8): how big its symbol is drawn, as a share of
// the room its cell gives a mark, and the size of its name. A village a little smaller, a city a little bigger, a great
// city (step 12a) bigger still.
// A landmark (step 12b; rpg_map_view: landmarks) by its symbol: a peak bigger, a standing stone or a cairn smaller.
const MAP_MARK_SIZE = { village: 0.8, town: 0.95, city: 1.1, great_city: 1.05, peak: 1.35, castle: 1.05, tower: 0.9, stones: 0.85, stone: 0.7, rock: 0.75, cairn: 0.7,
  cave: 0.85, mine: 0.85, shrine: 0.8, camp: 0.85, hut: 0.75 };
// A great city's mark grows with its people (rpg_map_view: towns' people), by the fourth root about the middle of their
// range (63,000): 20,000 draws at 0.75, 200,000 at 1.33. A landmark wider than its cell (its spot's width, thousandths of
// a cell) draws bigger, up to 1.8 times.
const mapMarkScale = (k) => (k.icon === "great_city" && k.people > 0 ? Math.min(1.35, Math.max(0.75, Math.pow(k.people / 63000, 0.25)))
  : k.landmark && Array.isArray(k.spot) && k.spot[2] > 1000 ? Math.min(1.8, k.spot[2] / 1000) : 1);
// The roads (step 8b), smallest first so the bigger lie on top: the inked edge (min = screen pixels wide at the least,
// dash for a lane) and the light middle (inset = screen pixels in from the edge; min for a highway, whose middle shows
// however far out the map is drawn).
const MAP_ROADS = [
  { k: 3, name: "Lane", edge: { line: "#8A6A48", min: 1.5, dash: [5, 3.5] }, mid: { line: "#E8D6A6", inset: 1.6 } },
  { k: 2, name: "Road", edge: { line: "#7A5A3A", min: 2.3 }, mid: { line: "#E8D6A6", inset: 2 } },
  { k: 1, name: "Highway", edge: { line: MAP_INK, min: 4.4 }, mid: { line: "#EDDDB0", inset: 2.2, min: 2 } },
];
const MAP_MARK_TEXT = { village: 10.5, town: 12, city: 13, great_city: 14.5, peak: 12, castle: 12, tower: 11, stones: 11, stone: 10.5, rock: 10.5, cairn: 10.5,
  cave: 10.5, mine: 10.5, shrine: 10.5, camp: 10.5, hut: 10.5 };
// The grounds drawn thick with symbols, where a landmark's mark gets a disc of paper behind it (step 12b).
const MAP_BUSY = ["mountains", "hills", "forest", "pine", "jungle", "swamp"];
// The squares a landmark stands on, seen from above on the battle grid (step 12b2; rpg_map_view: cells' climb, part
// first): cut stone for a keep, a castle wall and a tower, weathered stone for a ruin, grey slabs for standing stones,
// rough rock for a boulder, loose stones for a cairn, turf for a motte. round = how rounded the outline is; joints =
// draw the courses of the masonry.
const MAP_BUILT = {
  mound: { fill: "#8E9B5C", line: "#5E6A3A", w: 1, round: 0.45, o: 0.7 },
  curtain: { fill: "#C9C0AE", line: "#5C5446", w: 1.6, round: 0.05, joints: true },
  keep: { fill: "#BCB2A0", line: "#4E473B", w: 2, round: 0.02, joints: true },
  tower: { fill: "#C2B8A6", line: "#4E473B", w: 2, round: 0.45, joints: true },
  ruin: { fill: "#B7B29B", line: "#6B6450", w: 1.4, round: 0.15, joints: true },
  stone: { fill: "#A8A397", line: "#4F4A40", w: 1.4, round: 0.4 },
  boulder: { fill: "#A39C90", line: "#4F4A40", w: 1.6, round: 0.45 },
  cairn: { fill: "#BDB6AA", line: "#5C5446", w: 1.2, round: 0.45, pile: true },
  // the places to go into (step 12c): wattle for a hut, cut stone for a shrine and a wayside cross, bare rock round the
  // mouth of a cave or a mine, grey spoil heaps, a timber palisade, canvas tents
  hut: { fill: "#9C7A4E", line: "#5A4228", w: 1.6, round: 0.3 },
  shrine: { fill: "#C9C0AE", line: "#5C5446", w: 1.6, round: 0.1, joints: true },
  cross: { fill: "#B5AE9F", line: "#4F4A40", w: 1.4, round: 0.1 },
  outcrop: { fill: "#9F9787", line: "#4F4A40", w: 1.6, round: 0.4 },
  spoil: { fill: "#A9A296", line: "#6A6458", w: 1, round: 0.45, pile: true },
  palisade: { fill: "#A47E52", line: "#5E4426", w: 1.4, round: 0.1 },
  tent: { fill: "#E6DCC2", line: "#8A7A5A", w: 1.2, round: 0.3 },
};
// The squares of a place to go into walked like the ground (step 12c; rpg_map_view: cells' feature): the floor of a hut
// or a shrine, its hearth or altar, the mouth of a cave or a mine.
const MAP_FEATURE = {
  floor: { fill: "#D8C49A", line: "#9C8660", w: 0.8 },
  hearth: { fill: "#D8C49A", line: "#9C8660", w: 0.8, mark: { fill: "#C8642E", line: "#6E3218", r: 22 } },
  altar: { fill: "#D8C49A", line: "#9C8660", w: 0.8, mark: { fill: "#E4DDCB", line: "#4F4A40", r: 0, box: 26 } },
  mouth: { fill: "#2B211A", line: "#1A130E", w: 1, round: 0.3 },
};
// Bridges and fords (step 11; rpg_map_view: crossings), as the key names them: 1 a bridge, 2 a ford where a road
// crosses, 3 a planned ford off the roads.
const MAP_CROSSINGS = { 1: "Bridge", 2: "Ford", 3: "Ford" };
// A steady number from 0 to 1 for a spot on the map, so the same cell always draws the same way.
const mapRand = (a, b, c, d) => {
  let h = Math.imul((a | 0) + 0x9E3779B9, 0x85EBCA6B);
  h = Math.imul(h ^ (h >>> 15) ^ (b | 0), 0xC2B2AE35);
  h = Math.imul(h ^ (h >>> 13) ^ (c | 0), 0x27D4EB2F);
  h = Math.imul(h ^ (h >>> 16) ^ (d | 0), 0x165667B1);
  h = Math.imul(h ^ (h >>> 16), 0x85EBCA6B);
  h = Math.imul(h ^ (h >>> 13), 0xC2B2AE35);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
};
// A number to one decimal place, to keep the drawing's text short.
const mapNum = (n) => Math.round(n * 10) / 10;
const mapPt = (p) => `${mapNum(p[0])} ${mapNum(p[1])}`;
const mapLine = (pts) => "M" + pts.map(mapPt).join("L");
// A smooth open line through a chain of points: it passes the first and last and the midpoint between each pair in
// between, with the points themselves steering it (quadratic curves), so a chain of cell points reads as one bending
// line and not as a string of corners.
const mapBend = (pts) => {
  if (pts.length < 3) return mapLine(pts);
  let d = "M" + mapPt(pts[0]);
  for (let k = 1; k < pts.length - 1; k++) {
    const p = pts[k], q = pts[k + 1];
    d += "Q" + mapPt(p) + " " + mapPt(k === pts.length - 2 ? q : [(p[0] + q[0]) / 2, (p[1] + q[1]) / 2]);
  }
  return d;
};
const mapPoly = (pts) => mapLine(pts) + "Z";
// A bridge or a ford on the fantasy map (step 11): at x, y, the way across the water at angle a (radians, clockwise
// from east), L units long, over a road w units wide (0 for a planned ford). A bridge is an inked bar with a lighter
// deck and a post at each end; a ford is the way dotted through the water over a strip of the paper, so the river
// breaks where it is forded. The dots and the posts keep their size on the screen however far out the map is drawn.
const mapCrossing = (x, y, a, L, kind, w) => {
  const dx = Math.cos(a), dy = Math.sin(a), nx = -dy, ny = dx;
  const bar = mapLine([[x - dx * L / 2, y - dy * L / 2], [x + dx * L / 2, y + dy * L / 2]]);
  if (kind === 1) {
    const ph = Math.max(w * 1.1, L * 0.1);
    const post = (s) => mapLine([[x + dx * s * L / 2 - nx * ph, y + dy * s * L / 2 - ny * ph], [x + dx * s * L / 2 + nx * ph, y + dy * s * L / 2 + ny * ph]]);
    return [{ d: bar, line: MAP_INK, units: w * 1.7, min: 4.2, cap: "butt" }, { d: bar, line: "#C8A064", units: w * 1.7, inset: 2.4, min: 1.8, cap: "butt" }, { d: post(-1) + post(1), line: MAP_INK, units: 0, min: 1.6 }];
  }
  return [{ d: bar, line: MAP_PAPER.land, units: w * 1.4, min: 4.4, cap: "butt", o: 0.55 }, { d: bar, line: MAP_INK, units: 0, min: 2.4, dash: [0.01, 3.8], o: 0.9 }];
};
const mapCircle = (x, y, r) => `M${mapNum(x - r)} ${mapNum(y)}a${mapNum(r)} ${mapNum(r)} 0 1 0 ${mapNum(2 * r)} 0a${mapNum(r)} ${mapNum(r)} 0 1 0 ${mapNum(-2 * r)} 0Z`;
// A round shape with a bumpy edge: one big circle and smaller ones round it (a tree crown from above, a bush).
const mapBlob = (x, y, r, n, turn) => {
  let d = mapCircle(x, y, r * 0.72);
  for (let k = 0; k < n; k++) { const a = turn + k * 2 * Math.PI / n; d += mapCircle(x + Math.cos(a) * r * 0.64, y + Math.sin(a) * r * 0.64, r * 0.36); }
  return d;
};
// A spiky or rocky shape: points round a center, every other one pulled in, each a little uneven.
const mapStar = (x, y, r, n, inner, rnd, turn = 0) => mapPoly(Array.from({ length: n }, (_, k) => {
  const a = turn + k * 2 * Math.PI / n;
  const q = r * (k % 2 ? inner : 1) * (0.78 + 0.22 * rnd(40 + k));
  return [x + Math.cos(a) * q, y + Math.sin(a) * q];
}));
// The outline of a set of cells as closed shapes with rounded corners (SVG path data). inside(i, j) says whether a
// cell is in the set; it is asked one ring past the grid too, so a shape that runs off the grid is drawn running off.
// wob (the fantasy map: { lvl, x0, y0 } = the grid and where its first square sits in the world) draws the edge as a
// soft, wandering line instead (Peter 2026-10-04, 1B: soften the borders in the drawing): every side of a cell bends
// out or in by its own steady amount, the same whichever shape it is the edge of, so two grounds that meet share one
// line, and the line curves smoothly from side to side.
function mapOutline(cols, rows, inside, unit, round, wob) {
  const at = (i, j) => (i < -1 || j < -1 || i > cols || j > rows ? false : inside(i, j));
  const out = new Map();
  const put = (x0, y0, x1, y1) => { const k = x0 + "," + y0; const e = { x0, y0, x1, y1, used: false }; const l = out.get(k); if (l) l.push(e); else out.set(k, [e]); };
  for (let j = -1; j <= rows; j++) for (let i = -1; i <= cols; i++) {
    if (!at(i, j)) continue;
    if (!at(i, j - 1)) put(i, j, i + 1, j);
    if (!at(i + 1, j)) put(i + 1, j, i + 1, j + 1);
    if (!at(i, j + 1)) put(i + 1, j + 1, i, j + 1);
    if (!at(i - 1, j)) put(i, j + 1, i, j);
  }
  let d = "";
  out.forEach((list) => list.forEach((first) => {
    if (first.used) return;
    const run = [];
    let e = first;
    while (e && !e.used) {
      e.used = true;
      run.push(e);
      const dx = e.x1 - e.x0, dy = e.y1 - e.y0;
      const next = (out.get(e.x1 + "," + e.y1) || []).filter(n => !n.used);
      // where two cells touch only at a corner, keep to the cell being walked round (turn right)
      e = next.length > 1 ? (next.find(n => n.x1 - n.x0 === -dy && n.y1 - n.y0 === dx) || next[0]) : next[0];
    }
    const corners = [];
    run.forEach((p, k) => { const q = run[(k + run.length - 1) % run.length]; if (q.x1 - q.x0 !== p.x1 - p.x0 || q.y1 - q.y0 !== p.y1 - p.y0) corners.push([p.x0, p.y0]); });
    const n = corners.length;
    if (n < 4) return;
    if (wob) {
      // the middle of each side, moved across the side by up to 0.3 of a cell and along it by up to 0.2, from where
      // the side lies in the world; the line runs smoothly from one side's point to the next
      const pts = run.map(e => {
        const flat = e.y0 === e.y1, kx = Math.min(e.x0, e.x1), ky = Math.min(e.y0, e.y1);
        const across = (mapRand(wob.lvl, wob.x0 + kx, wob.y0 + ky, flat ? 503 : 504) - 0.5) * 0.6;
        const along = (mapRand(wob.lvl, wob.x0 + kx, wob.y0 + ky, flat ? 505 : 506) - 0.5) * 0.4;
        return flat ? [kx + 0.5 + along, ky + across] : [kx + across, ky + 0.5 + along];
      });
      const m = pts.length;
      const half = (p, q) => [(p[0] + q[0]) / 2 * unit, (p[1] + q[1]) / 2 * unit];
      d += "M" + mapPt(half(pts[m - 1], pts[0]));
      pts.forEach((p, k) => { d += "Q" + mapPt([p[0] * unit, p[1] * unit]) + " " + mapPt(half(p, pts[(k + 1) % m])); });
      d += "Z";
      return;
    }
    corners.forEach((c, k) => {
      const a = corners[(k + n - 1) % n], b = corners[(k + 1) % n];
      const ra = Math.min(round, (Math.abs(c[0] - a[0]) + Math.abs(c[1] - a[1])) / 2), rb = Math.min(round, (Math.abs(b[0] - c[0]) + Math.abs(b[1] - c[1])) / 2);
      const pa = [(c[0] + Math.sign(a[0] - c[0]) * ra) * unit, (c[1] + Math.sign(a[1] - c[1]) * ra) * unit];
      const pb = [(c[0] + Math.sign(b[0] - c[0]) * rb) * unit, (c[1] + Math.sign(b[1] - c[1]) * rb) * unit];
      d += (k === 0 ? "M" : "L") + mapPt(pa) + "Q" + mapPt([c[0] * unit, c[1] * unit]) + " " + mapPt(pb);
    });
    d += "Z";
  }));
  return d;
}
// The ground not found yet, as strokes to paint last: the dark itself, specks of light scattered over it (the same
// specks every time, seven to a cell of the grid, in three sizes), and the lines of the grid in a faint light so its
// cells still show. unknown(i, j) says whether a square of the drawing (unit wide) is not found yet; cols and rows
// are the cells of the grid, lvl, x0, y0 where the grid is in the world.
function mapFog(C, R, unit, unknown, round, cols, rows, lvl, x0, y0) {
  const shape = mapOutline(C, R, unknown, unit, round);
  if (!shape) return [];
  const at = (x, y) => { const i = Math.floor(x / unit), j = Math.floor(y / unit); return i >= 0 && j >= 0 && i < C && j < R && unknown(i, j); };
  const dots = ["", "", ""];
  for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++) for (let n = 0; n < 7; n++) {
    const x = (i + mapRand(lvl, x0 + i, y0 + j, 900 + n * 2)) * 100, y = (j + mapRand(lvl, x0 + i, y0 + j, 901 + n * 2)) * 100;
    if (at(x, y)) dots[n === 0 ? 2 : n < 3 ? 1 : 0] += `M${mapNum(x)} ${mapNum(y)}h0.01`;
  }
  let lines = "";
  const run = (len, hit, seg) => { let from = -1; for (let k = 0; k <= len; k++) { const on = k < len && hit(k); if (on && from < 0) from = k; if (!on && from >= 0) { lines += seg(from, k); from = -1; } } };
  for (let i = 1; i < cols; i++) { const g = Math.round(i * 100 / unit); run(R, (k) => unknown(g - 1, k) || unknown(g, k), (a, b) => `M${i * 100} ${mapNum(a * unit)}V${mapNum(b * unit)}`); }
  for (let j = 1; j < rows; j++) { const g = Math.round(j * 100 / unit); run(C, (k) => unknown(k, g - 1) || unknown(k, g), (a, b) => `M${mapNum(a * unit)} ${j * 100}H${mapNum(b * unit)}`); }
  return [{ d: shape, fill: MAP_FOG.dark }, { d: dots[0], line: MAP_FOG.speck, w: 1, o: 0.45 }, { d: dots[1], line: MAP_FOG.speck, w: 1.6, o: 0.7 }, { d: dots[2], line: MAP_FOG.speck, w: 2.3, o: 0.9 }, { d: lines, line: MAP_FOG.line, w: 0.8, o: 0.14 }].filter(l => l.d);
}
// Strokes kept in rows from the top of the map down, so a tree lower on the map overlaps the one above it.
function mapRows(step) {
  const rows = new Map();
  return {
    add(y, k, d) { const b = Math.round(y / step); let r = rows.get(b); if (!r) { r = {}; rows.set(b, r); } r[k] = (r[k] || "") + d; },
    list(styles) {
      const out = [];
      Array.from(rows.keys()).sort((a, b) => a - b).forEach(b => { const r = rows.get(b); styles.forEach(s => { if (r[s.k]) out.push({ ...s, d: r[s.k] }); }); });
      return out;
    },
  };
}
// The fantasy-map symbols, one stroke at a time. x, base = the foot of the symbol.
const mapTree = (add, x, base, d, tone = "crown") => {
  const cy = base - d * 0.72;
  const p0 = [x - d * 0.5, cy + d * 0.18], p1 = [x - d * 0.28, cy - d * 0.3], p2 = [x + d * 0.28, cy - d * 0.3], p3 = [x + d * 0.5, cy + d * 0.18];
  const arc = (r, ry, p) => `A${mapNum(d * r)} ${mapNum(d * ry)} 0 0 1 ${mapPt(p)}`;
  const crown = "M" + mapPt(p0) + arc(0.3, 0.3, p1) + arc(0.32, 0.32, p2) + arc(0.3, 0.3, p3) + arc(0.62, 0.36, p0) + "Z";
  add(base, "trunk", mapLine([[x, base], [x, base - d * 0.42]]));
  add(base, tone, crown);
  add(base, tone + "Shade", "M" + mapPt([x + d * 0.14, cy - d * 0.36]) + `Q${mapPt([x + d * 0.5, cy - d * 0.2])} ${mapPt([x + d * 0.42, cy + d * 0.16])}Q${mapPt([x + d * 0.24, cy + d * 0.3])} ${mapPt([x + d * 0.04, cy + d * 0.28])}Q${mapPt([x + d * 0.34, cy + d * 0.04])} ${mapPt([x + d * 0.14, cy - d * 0.36])}Z`);
  add(base, "crownLine", crown);
};
const mapPine = (add, x, base, d) => {
  const h = d * 1.3, w = d * 0.46, top = base - h;
  add(base, "trunk", mapLine([[x, base], [x, base - h * 0.2]]));
  add(base, "pine", mapPoly([[x, top + h * 0.45], [x + w, base - h * 0.14], [x - w, base - h * 0.14]]) + mapPoly([[x, top + h * 0.2], [x + w * 0.78, top + h * 0.62], [x - w * 0.78, top + h * 0.62]]) + mapPoly([[x, top], [x + w * 0.52, top + h * 0.36], [x - w * 0.52, top + h * 0.36]]));
};
// A palm: a leaning trunk and five fronds hanging from its top.
const mapPalm = (add, x, base, d) => {
  const top = [x + d * 0.12, base - d * 0.95];
  add(base, "trunk", `M${mapPt([x, base])}Q${mapPt([x - d * 0.02, base - d * 0.5])} ${mapPt(top)}`);
  add(base, "frond", [[-0.42, 0.1], [-0.28, -0.14], [0.02, -0.22], [0.32, -0.12], [0.46, 0.12]].map(([u, v]) => `M${mapPt(top)}Q${mapPt([top[0] + u * d * 0.6, top[1] + v * d - d * 0.14])} ${mapPt([top[0] + u * d, top[1] + v * d + d * 0.12])}`).join(""));
};
const mapPeak = (add, x, base, w, h, lean) => {
  const a = [x + lean * w, base - h], bl = [x - w / 2, base], br = [x + w / 2, base];
  const k1 = [x + (lean - 0.09) * w, base - h * 0.62], k2 = [x + (lean + 0.1) * w, base - h * 0.3], kb = [x + lean * w * 0.5, base];
  add(base, "peakLight", mapPoly([bl, a, k1, k2, kb]));
  add(base, "peakShade", mapPoly([a, br, kb, k2, k1]));
  add(base, "peakLine", mapLine([bl, a, br]) + mapLine([a, k1, k2, kb]));
};
const mapHump = (add, x, base, w, h) => {
  const c = `M${mapPt([x - w / 2, base])}C${mapPt([x - w * 0.3, base - h * 1.3])} ${mapPt([x + w * 0.3, base - h * 1.3])} ${mapPt([x + w / 2, base])}`;
  add(base, "hillFill", c + "Z");
  add(base, "hillLine", c + mapLine([[x + w * 0.2, base - h * 0.62], [x + w * 0.29, base - h * 0.24]]) + mapLine([[x + w * 0.07, base - h * 0.8], [x + w * 0.15, base - h * 0.4]]));
};
const mapTuft = (add, x, base, s, k = "tuft") => add(base, k, mapLine([[x, base], [x - s * 0.3, base - s * 0.7]]) + mapLine([[x, base], [x, base - s]]) + mapLine([[x, base], [x + s * 0.3, base - s * 0.7]]));
const mapHouse = (add, x, base, s) => {
  add(base, "wall", mapPoly([[x - s * 0.3, base], [x - s * 0.3, base - s * 0.42], [x + s * 0.3, base - s * 0.42], [x + s * 0.3, base]]));
  add(base, "roof", mapPoly([[x - s * 0.42, base - s * 0.4], [x, base - s * 0.88], [x + s * 0.42, base - s * 0.4]]));
  add(base, "door", mapLine([[x, base], [x, base - s * 0.22]]));
};
// A church: a tall narrow wall under a steep spire.
const mapSpire = (add, x, base, s) => {
  add(base, "wall", mapPoly([[x - s * 0.15, base], [x - s * 0.15, base - s * 0.6], [x + s * 0.15, base - s * 0.6], [x + s * 0.15, base]]));
  add(base, "roof", mapPoly([[x - s * 0.21, base - s * 0.58], [x, base - s * 1.2], [x + s * 0.21, base - s * 0.58]]));
  add(base, "door", mapLine([[x, base], [x, base - s * 0.2]]));
};
// A stone tower with battlements and a window.
const mapTower = (add, x, base, s) => {
  const w = s * 0.17, h = s * 0.72, q = w * 2 / 5, top = base - h;
  add(base, "stone", mapPoly([[x - w, base], [x - w, top - q], [x - w + q, top - q], [x - w + q, top], [x - w + 2 * q, top], [x - w + 2 * q, top - q], [x - w + 3 * q, top - q], [x - w + 3 * q, top], [x - w + 4 * q, top], [x - w + 4 * q, top - q], [x + w, top - q], [x + w, base]]));
  add(base, "hole", mapPoly([[x - w * 0.22, top + h * 0.3], [x + w * 0.22, top + h * 0.3], [x + w * 0.22, top + h * 0.48], [x - w * 0.22, top + h * 0.48]]));
};
// MAP_ART: the drawing for each kind of ground and each symbol a place card can name (rpg_map_icons), in both
// styles. fantasy[name](add, x, y, s, rnd, few) draws it in the square at x, y of side s; few = a small or crowded
// spot, so one or two strokes of it and not a full cell's worth. top[name] says how a battle square of it looks.
const MAP_ART = {
  // The strokes of the fantasy map, in the order they are painted within one row.
  ink: [
    { k: "hillFill", fill: "#DCC98F" }, { k: "hillLine", line: MAP_INK, w: 1 },
    { k: "peakLight", fill: "#F1EBDA" }, { k: "peakShade", fill: "#A99A86" }, { k: "peakLine", line: MAP_INK, w: 1 },
    { k: "den", fill: "#84705B", line: MAP_INK, w: 1 }, { k: "hole", fill: "#2B211A" },
    { k: "stone", fill: "#DDD6C4", line: MAP_INK, w: 1 },
    { k: "trunk", line: MAP_INK, w: 1.1 }, { k: "crown", fill: "#93A86D" }, { k: "crownShade", fill: "#738A54" },
    { k: "jungle", fill: "#6E9A4E" }, { k: "jungleShade", fill: "#557E3B" }, { k: "crownLine", line: MAP_INK, w: 1 }, { k: "frond", line: "#4E7A35", w: 1.4 },
    { k: "pine", fill: "#6F8B5B", line: MAP_INK, w: 1 },
    { k: "thorn", fill: "#8D9245", line: MAP_INK, w: 0.9 },
    { k: "wall", fill: "#F6EED8", line: MAP_INK, w: 1 }, { k: "roof", fill: "#B4633C", line: MAP_INK, w: 1 }, { k: "door", line: MAP_INK, w: 1 },
    { k: "tuft", line: "#7A8A4C", w: 0.9 }, { k: "tuftDry", line: "#9C9450", w: 0.9 }, { k: "tuftCold", line: "#8A9579", w: 0.9 },
    { k: "dip", line: "#8C8156", w: 1 }, { k: "stream", line: "#6C9BAE", w: 1.5 }, { k: "marsh", line: "#7FA0A0", w: 1.2 }, { k: "reed", line: "#5C6B37", w: 1 },
    { k: "dune", line: "#B0925A", w: 1.1 }, { k: "drift", fill: "#FBFCFC", line: "#A9BFCB", w: 0.9 }, { k: "ridge", line: "#8EA9B8", w: 1 },
    { k: "mist", line: "#8E8AA3", w: 1.7 }, { k: "wave", line: "#8DAEB1", w: 1 },
  ],
  fantasy: {
    sea(add, x, y, s, rnd, few) {
      if (rnd(1) > (few ? 0.012 : 0.2)) return;
      const cx = x + (0.3 + rnd(2) * 0.4) * s, cy = y + (0.3 + rnd(3) * 0.4) * s, w = s * (few ? 1.2 : 0.2);
      add(cy, "wave", `M${mapPt([cx - w, cy])}Q${mapPt([cx - w / 2, cy - w * 0.6])} ${mapPt([cx, cy])}T${mapPt([cx + w, cy])}`);
    },
    land(add, x, y, s, rnd, few) {
      if (few || rnd(1) > 0.3) return;
      mapTuft(add, x + (0.25 + rnd(2) * 0.5) * s, y + (0.35 + rnd(3) * 0.5) * s, s * 0.11);
    },
    forest(add, x, y, s, rnd, few, dark) {
      if (few) { (dark || rnd(1) < 0.2 ? mapPine : mapTree)(add, x + (0.5 + (rnd(2) - 0.5) * 0.3) * s, y + (0.96 + (rnd(3) - 0.5) * 0.2) * s, s * (0.9 + rnd(4) * 0.25)); return; }
      [[0.24, 0.4], [0.72, 0.34], [0.48, 0.66], [0.2, 0.94], [0.78, 0.92]].forEach(([u, v], k) => {
        (dark || rnd(20 + k) < 0.2 ? mapPine : mapTree)(add, x + (u + (rnd(k) - 0.5) * 0.14) * s, y + (v + (rnd(10 + k) - 0.5) * 0.1) * s, s * (0.3 + rnd(30 + k) * 0.08));
      });
    },
    hills(add, x, y, s, rnd, few) {
      if (few) { mapHump(add, x + (0.5 + (rnd(1) - 0.5) * 0.3) * s, y + (0.8 + (rnd(2) - 0.5) * 0.2) * s, s * 1.25, s * 0.5); return; }
      [[0.3, 0.46, 0.46], [0.7, 0.58, 0.42], [0.42, 0.88, 0.5]].forEach(([u, v, w], k) => mapHump(add, x + (u + (rnd(k) - 0.5) * 0.12) * s, y + (v + (rnd(10 + k) - 0.5) * 0.08) * s, s * w, s * w * 0.42));
    },
    mountains(add, x, y, s, rnd, few) {
      if (few) { mapPeak(add, x + (0.5 + (rnd(1) - 0.5) * 0.3) * s, y + (0.98 + (rnd(2) - 0.5) * 0.16) * s, s * (1.3 + rnd(3) * 0.4), s * (1.1 + rnd(4) * 0.5), (rnd(5) - 0.5) * 0.16); return; }
      [[0.38, 0.7, 0.66, 0.6], [0.74, 0.94, 0.48, 0.4], [0.2, 0.96, 0.34, 0.28]].forEach(([u, v, w, h], k) => mapPeak(add, x + (u + (rnd(k) - 0.5) * 0.1) * s, y + (v + (rnd(10 + k) - 0.5) * 0.06) * s, s * w, s * h * (0.9 + rnd(20 + k) * 0.3), (rnd(30 + k) - 0.5) * 0.16));
    },
    village(add, x, y, s, rnd, few) {
      if (few) { [[0.3, 0.62, 0.34], [0.68, 0.56, 0.4], [0.5, 0.9, 0.36]].forEach(([u, v, w]) => mapHouse(add, x + u * s, y + v * s, s * w)); return; }
      [[0.26, 0.46], [0.72, 0.4], [0.5, 0.88]].forEach(([u, v], k) => { if (k === 0 || rnd(k) < 0.55) mapHouse(add, x + (u + (rnd(5 + k) - 0.5) * 0.2) * s, y + (v + (rnd(10 + k) - 0.5) * 0.14) * s, s * (0.28 + rnd(15 + k) * 0.14)); });
    },
    // a town (step 8): houses round a church; a cell of its ground, houses closer together and now and then a church
    town(add, x, y, s, rnd, few) {
      if (few) { mapSpire(add, x + 0.5 * s, y + 0.66 * s, s * 0.62); mapHouse(add, x + 0.22 * s, y + 0.92 * s, s * 0.36); mapHouse(add, x + 0.78 * s, y + 0.9 * s, s * 0.38); return; }
      [[0.25, 0.42], [0.72, 0.38], [0.3, 0.86], [0.74, 0.84]].forEach(([u, v], k) => {
        if (k > 1 && rnd(k) > 0.65) return;
        const px = x + (u + (rnd(5 + k) - 0.5) * 0.12) * s, py = y + (v + (rnd(10 + k) - 0.5) * 0.1) * s;
        if (k === 0 && rnd(20) < 0.18) mapSpire(add, px, py, s * 0.42); else mapHouse(add, px, py, s * (0.24 + rnd(15 + k) * 0.1));
      });
    },
    // a city (step 8): houses and a church behind a wall with towers and a gate; a cell of its ground, houses packed
    // close and now and then a tower
    city(add, x, y, s, rnd, few) {
      if (few) {
        mapHouse(add, x + 0.27 * s, y + 0.6 * s, s * 0.34); mapSpire(add, x + 0.53 * s, y + 0.56 * s, s * 0.52); mapHouse(add, x + 0.77 * s, y + 0.62 * s, s * 0.32);
        const b = y + 0.94 * s, t = y + 0.75 * s;
        add(b, "stone", mapPoly([[x + 0.14 * s, b], [x + 0.14 * s, t], [x + 0.44 * s, t], [x + 0.44 * s, b]]) + mapPoly([[x + 0.56 * s, b], [x + 0.56 * s, t], [x + 0.86 * s, t], [x + 0.86 * s, b]]));
        add(b, "hole", `M${mapPt([x + 0.44 * s, b])}L${mapPt([x + 0.44 * s, t + 0.06 * s])}Q${mapPt([x + 0.5 * s, t - 0.01 * s])} ${mapPt([x + 0.56 * s, t + 0.06 * s])}L${mapPt([x + 0.56 * s, b])}Z`);
        mapTower(add, x + 0.14 * s, b, s * 0.5); mapTower(add, x + 0.86 * s, b, s * 0.5);
        return;
      }
      [[0.22, 0.36], [0.55, 0.32], [0.82, 0.4], [0.3, 0.72], [0.64, 0.7], [0.48, 0.98]].forEach(([u, v], k) => {
        if (k > 3 && rnd(k) > 0.6) return;
        const px = x + (u + (rnd(5 + k) - 0.5) * 0.1) * s, py = y + (v + (rnd(10 + k) - 0.5) * 0.08) * s;
        if (k === 1 && rnd(20) < 0.12) mapTower(add, px, py, s * 0.5); else mapHouse(add, px, py, s * (0.22 + rnd(15 + k) * 0.08));
      });
    },
    // a great city (step 12a): a long wall with a tower at each end and a gate between two more, packed roofs behind
    // it, a cathedral with two spires and a keep; a cell of its ground, houses packed closer than a city's, now and
    // then a spire or a tower
    great_city(add, x, y, s, rnd, few) {
      if (few) {
        mapHouse(add, x + 0.17 * s, y + 0.64 * s, s * 0.3); mapHouse(add, x + 0.3 * s, y + 0.6 * s, s * 0.28); mapHouse(add, x + 0.85 * s, y + 0.64 * s, s * 0.3);
        mapSpire(add, x + 0.44 * s, y + 0.62 * s, s * 0.6); mapSpire(add, x + 0.58 * s, y + 0.62 * s, s * 0.6);
        mapTower(add, x + 0.72 * s, y + 0.66 * s, s * 0.66);
        const b = y + 0.96 * s, t = y + 0.79 * s;
        add(b, "stone", mapPoly([[x + 0.05 * s, b], [x + 0.05 * s, t], [x + 0.45 * s, t], [x + 0.45 * s, b]]) + mapPoly([[x + 0.55 * s, b], [x + 0.55 * s, t], [x + 0.95 * s, t], [x + 0.95 * s, b]]));
        add(b, "hole", `M${mapPt([x + 0.45 * s, b])}L${mapPt([x + 0.45 * s, t + 0.06 * s])}Q${mapPt([x + 0.5 * s, t - 0.01 * s])} ${mapPt([x + 0.55 * s, t + 0.06 * s])}L${mapPt([x + 0.55 * s, b])}Z`);
        mapTower(add, x + 0.05 * s, b, s * 0.52); mapTower(add, x + 0.41 * s, b, s * 0.46); mapTower(add, x + 0.59 * s, b, s * 0.46); mapTower(add, x + 0.95 * s, b, s * 0.52);
        return;
      }
      [[0.18, 0.32], [0.5, 0.28], [0.82, 0.34], [0.33, 0.62], [0.67, 0.6], [0.16, 0.94], [0.5, 0.92], [0.84, 0.96]].forEach(([u, v], k) => {
        if (k > 5 && rnd(k) > 0.75) return;
        const px = x + (u + (rnd(5 + k) - 0.5) * 0.08) * s, py = y + (v + (rnd(10 + k) - 0.5) * 0.06) * s;
        if (k === 1 && rnd(20) < 0.16) mapSpire(add, px, py, s * 0.46);
        else if (k === 4 && rnd(21) < 0.12) mapTower(add, px, py, s * 0.5);
        else mapHouse(add, px, py, s * (0.2 + rnd(15 + k) * 0.07));
      });
    },
    // the landmarks (step 12b; rpg_map_landmark_kinds), each drawn whole as a mark: a lone peak and a lower shoulder
    // with snow on its top, so it stands out among the peaks of a mountain range
    peak(add, x, y, s, rnd, few) {
      const base = y + 0.96 * s, cx = x + 0.46 * s, w = s * 0.86, h = s * 0.92, lean = -0.03;
      mapPeak(add, x + 0.74 * s, base, s * 0.52, s * 0.42, 0.04);
      mapPeak(add, cx, base, w, h, lean);
      const a = [cx + lean * w, base - h], t = 0.32, l = [a[0] - (a[0] - (cx - w / 2)) * t, a[1] + h * t], r = [a[0] + (cx + w / 2 - a[0]) * t, a[1] + h * t];
      add(base, "drift", mapPoly([a, r, [a[0] + (r[0] - a[0]) * 0.45, r[1] - h * 0.07], [a[0] + w * 0.02, r[1] + h * 0.03], [a[0] - (a[0] - l[0]) * 0.5, l[1] - h * 0.08], l]));
    },
    // a castle: a keep behind a crenellated wall with a gate, a tower at each end
    castle(add, x, y, s, rnd, few) {
      const b = y + 0.94 * s, t = b - 0.3 * s, q = s * 0.05;
      mapTower(add, x + 0.5 * s, b - 0.26 * s, s * 0.95);
      const top = [];
      for (let u = x + 0.2 * s; u < x + 0.8 * s - 0.5 * q; u += 2 * q) top.push([u, t], [u, t - q], [u + q, t - q], [u + q, t]);
      add(b, "stone", mapPoly([[x + 0.2 * s, b], ...top, [x + 0.8 * s, t], [x + 0.8 * s, b]]));
      add(b, "hole", `M${mapPt([x + 0.44 * s, b])}L${mapPt([x + 0.44 * s, b - 0.13 * s])}Q${mapPt([x + 0.5 * s, b - 0.21 * s])} ${mapPt([x + 0.56 * s, b - 0.13 * s])}L${mapPt([x + 0.56 * s, b])}Z`);
      mapTower(add, x + 0.2 * s, b, s * 0.62); mapTower(add, x + 0.8 * s, b, s * 0.62);
    },
    // a tower standing alone, a pennant on its top
    tower(add, x, y, s, rnd, few) {
      const b = y + 0.96 * s, h = s * 1.15 * 0.72, w = s * 1.15 * 0.17, top = b - h - w * 0.4, cx = x + 0.5 * s;
      mapTower(add, cx, b, s * 1.15);
      add(b, "door", mapLine([[cx, top], [cx, top - s * 0.16]]));
      add(b, "roof", mapPoly([[cx, top - s * 0.16], [cx + s * 0.14, top - s * 0.12], [cx, top - s * 0.08]]));
    },
    // a stone circle: eight stones round a ring, those at the back smaller
    stones(add, x, y, s, rnd, few) {
      const cx = x + 0.5 * s, cy = y + 0.68 * s, rx = 0.36 * s, ry = 0.15 * s;
      for (let k = 0; k < 8; k++) {
        const a = k * Math.PI / 4 + 0.3, px = cx + rx * Math.cos(a), py = cy + ry * Math.sin(a), back = Math.sin(a) < 0;
        const h = s * (back ? 0.17 : 0.24) * (0.85 + 0.3 * rnd(k)), w = s * (back ? 0.05 : 0.065);
        add(py, "stone", mapPoly([[px - w, py], [px - w * 0.85, py - h], [px + w * 0.85, py - h], [px + w, py]]));
      }
    },
    // a standing stone: one tall stone, a little tapered and rounded at the top
    stone(add, x, y, s, rnd, few) {
      const cx = x + 0.5 * s, b = y + 0.94 * s, h = s * 0.7, w = s * 0.13;
      add(b, "stone", `M${mapPt([cx - w, b])}L${mapPt([cx - w * 0.8, b - h * 0.85])}Q${mapPt([cx - w * 0.2, b - h * 1.05])} ${mapPt([cx + w * 0.7, b - h * 0.92])}L${mapPt([cx + w, b])}Z`);
      add(b, "hillLine", mapLine([[cx - w * 1.8, b], [cx + w * 1.8, b]]));
    },
    // a boulder, with a crack down it
    rock(add, x, y, s, rnd, few) {
      const cx = x + 0.5 * s, b = y + 0.9 * s, w = s * 0.42, h = s * 0.42;
      add(b, "stone", `M${mapPt([cx - w, b])}C${mapPt([cx - w * 1.05, b - h * 0.8])} ${mapPt([cx - w * 0.3, b - h * 1.1])} ${mapPt([cx + w * 0.15, b - h])}C${mapPt([cx + w * 0.8, b - h * 0.95])} ${mapPt([cx + w * 1.05, b - h * 0.4])} ${mapPt([cx + w, b])}Z`);
      add(b, "peakLine", mapLine([[cx + w * 0.1, b - h * 0.95], [cx, b - h * 0.55], [cx + w * 0.2, b - h * 0.3]]));
    },
    // a cairn: a heap of stones, three, two, then one
    cairn(add, x, y, s, rnd, few) {
      const r = s * 0.11, b = y + 0.94 * s;
      [[3, 0], [2, 1], [1, 2]].forEach(([n, row]) => {
        const py = b - r - row * r * 1.6;
        for (let k = 0; k < n; k++) add(b - row * 0.01, "stone", mapCircle(x + 0.5 * s + (k - (n - 1) / 2) * r * 1.9, py, r));
      });
    },
    // the places to go into (step 12c; rpg_map_location_kinds): a cave, a dark mouth in a knoll of rock
    cave(add, x, y, s, rnd, few) {
      const cx = x + s * 0.5, base = y + s * 0.9, w = s * 0.92, h = s * 0.48;
      add(base, "stone", `M${mapPt([cx - w / 2, base])}C${mapPt([cx - w * 0.42, base - h * 1.2])} ${mapPt([cx + w * 0.1, base - h * 1.45])} ${mapPt([cx + w * 0.22, base - h * 1.1])}C${mapPt([cx + w * 0.4, base - h * 1.05])} ${mapPt([cx + w * 0.5, base - h * 0.5])} ${mapPt([cx + w / 2, base])}Z`);
      add(base, "hole", `M${mapPt([cx - w * 0.16, base])}C${mapPt([cx - w * 0.16, base - h * 0.85])} ${mapPt([cx + w * 0.16, base - h * 0.85])} ${mapPt([cx + w * 0.16, base])}Z`);
    },
    // a mine: an adit in a hillside, its timber frame, a heap of spoil beside it
    mine(add, x, y, s, rnd, few) {
      const cx = x + s * 0.42, base = y + s * 0.9, w = s * 0.13, h = s * 0.3;
      mapHump(add, cx, base, s * 0.8, s * 0.42);
      add(base, "hole", mapPoly([[cx - w, base], [cx - w, base - h], [cx + w, base - h], [cx + w, base]]));
      add(base, "door", mapLine([[cx - w * 1.2, base], [cx - w * 1.2, base - h * 1.1], [cx + w * 1.2, base - h * 1.1], [cx + w * 1.2, base]]));
      [[0.78, 0.07], [0.88, 0.055], [0.83, 0.05]].forEach(([u, r], k) => add(base + 0.01 * k, "stone", mapCircle(x + u * s, base - r * s * (k === 2 ? 2.4 : 1), r * s)));
    },
    // a shrine: a small chapel under a steep roof
    shrine(add, x, y, s, rnd, few) { mapSpire(add, x + s * 0.5, y + s * 0.94, s * 0.8); },
    // a camp: two tents
    camp(add, x, y, s, rnd, few) {
      [[0.34, 0.86, 0.5], [0.68, 0.94, 0.42]].forEach(([u, v, k]) => {
        const cx = x + u * s, b = y + v * s, w = s * k / 2, h = s * k * 0.75;
        add(b, "wall", mapPoly([[cx - w, b], [cx, b - h], [cx + w, b]]));
        add(b, "door", mapLine([[cx, b - h], [cx, b]]) + mapLine([[cx, b - h], [cx - w * 0.25, b]]));
      });
    },
    // a hut: one small house
    hut(add, x, y, s, rnd, few) { mapHouse(add, x + s * 0.5, y + s * 0.92, s * 0.9); },
    ruins(add, x, y, s, rnd, few) {
      if (!few && rnd(1) > 0.3) { if (rnd(2) < 0.4) mapTuft(add, x + (0.3 + rnd(3) * 0.4) * s, y + (0.4 + rnd(4) * 0.4) * s, s * 0.11); return; }
      const k = few ? 1.5 : 1, base = y + s * (few ? 0.84 : 0.55 + rnd(5) * 0.35), cx = x + s * (few ? 0.5 : 0.3 + rnd(6) * 0.4), w = s * 0.05 * k;
      const col = (dx, h) => { const px = cx + dx * s * k, top = base - h * s * k; add(base, "stone", mapPoly([[px - w, base], [px - w, top + w * 0.7], [px - w * 0.2, top], [px + w * 0.4, top + w * 0.9], [px + w, top + w * 0.3], [px + w, base]])); return top; };
      const kind = few ? 1 : Math.floor(rnd(7) * 3);
      if (kind === 0) { col(-0.17, 0.3 + rnd(8) * 0.14); col(0, 0.14 + rnd(9) * 0.12); col(0.17, 0.22 + rnd(10) * 0.14); }
      if (kind === 1) {
        const top = col(-0.14, 0.4), l = cx - 0.14 * s * k, r = s * 0.2 * k;
        col(0.16, 0.2 + rnd(11) * 0.08);
        add(base, "stone", "M" + mapPt([l - w, top + w]) + `Q${mapPt([l - w, top - r])} ${mapPt([l + r * 0.9, top - r * 1.05])}L${mapPt([l + r * 0.8, top - r * 0.6])}Q${mapPt([l + w, top - r * 0.5])} ${mapPt([l + w, top + w])}Z`);
      }
      if (kind === 2) [[-0.16, 0.05, 0.3], [0.04, 0.07, -0.2], [0.18, 0.045, 0.6]].forEach(([dx, r, t]) => { const px = cx + dx * s, c = Math.cos(t), q = Math.sin(t), h = r * s * 0.62; add(base, "stone", mapPoly([[-1, -1], [1, -1], [1, 1], [-1, 1]].map(([u, v]) => [px + u * r * s * c - v * h * q, base - h + u * r * s * q + v * h * c]))); });
      if (kind < 2) add(base, "stone", mapPoly([[cx - s * 0.27 * k, base], [cx - s * 0.27 * k, base + w], [cx + s * 0.27 * k, base + w], [cx + s * 0.27 * k, base]]));
    },
    lair(add, x, y, s, rnd, few) {
      if (!few) { MAP_ART.fantasy.forest(add, x, y, s, rnd, false, true); return; }
      const cx = x + s * 0.5, base = y + s * 0.88, w = s * 0.9, h = s * 0.5;
      add(base, "den", `M${mapPt([cx - w / 2, base])}C${mapPt([cx - w * 0.34, base - h * 1.5])} ${mapPt([cx + w * 0.34, base - h * 1.5])} ${mapPt([cx + w / 2, base])}Z`);
      add(base, "hole", `M${mapPt([cx - w * 0.17, base])}C${mapPt([cx - w * 0.17, base - h * 0.95])} ${mapPt([cx + w * 0.17, base - h * 0.95])} ${mapPt([cx + w * 0.17, base])}Z`);
    },
    valley(add, x, y, s, rnd, few) {
      if (few) {
        mapHump(add, x + s * 0.24, y + s * 0.8, s * 0.6, s * 0.3); mapHump(add, x + s * 0.76, y + s * 0.8, s * 0.6, s * 0.3);
        add(y + s * 0.82, "stream", `M${mapPt([x + s * 0.5, y + s * 0.3])}Q${mapPt([x + s * 0.4, y + s * 0.5])} ${mapPt([x + s * 0.52, y + s * 0.66])}T${mapPt([x + s * 0.48, y + s * 0.98])}`);
        return;
      }
      [[0.3, 0.36], [0.68, 0.62]].forEach(([u, v], k) => { const cx = x + (u + (rnd(k) - 0.5) * 0.16) * s, cy = y + (v + (rnd(5 + k) - 0.5) * 0.12) * s, w = s * 0.17; add(cy, "dip", `M${mapPt([cx - w, cy - w * 0.5])}Q${mapPt([cx, cy + w * 0.7])} ${mapPt([cx + w, cy - w * 0.5])}`); });
      mapTuft(add, x + (0.3 + rnd(8) * 0.4) * s, y + (0.86 + rnd(9) * 0.08) * s, s * 0.11);
    },
    fog(add, x, y, s, rnd, few) {
      (few ? [0.3, 0.52, 0.74] : [0.26 + rnd(1) * 0.1, 0.56 + rnd(2) * 0.1, 0.84]).forEach((v, k) => {
        const w = s * (few ? 0.18 : 0.15), x0 = x + s * (0.14 + (k % 2) * 0.1 + (few ? 0 : (rnd(3 + k) - 0.5) * 0.1)), cy = y + v * s;
        add(cy, "mist", `M${mapPt([x0, cy])}q${mapNum(w / 2)} ${mapNum(-w * 0.55)} ${mapNum(w)} 0t${mapNum(w)} 0t${mapNum(w)} 0t${mapNum(w)} 0`);
      });
    },
    thorns(add, x, y, s, rnd, few) {
      (few ? [[0.32, 0.5, 0.26], [0.7, 0.62, 0.22]] : [[0.26, 0.34, 0.14], [0.7, 0.3, 0.12], [0.5, 0.64, 0.15], [0.2, 0.84, 0.11], [0.8, 0.82, 0.13]]).forEach(([u, v, r], k) => {
        const cx = x + (u + (few ? 0 : (rnd(k) - 0.5) * 0.1)) * s, cy = y + (v + (few ? 0 : (rnd(8 + k) - 0.5) * 0.1)) * s;
        add(cy + r * s, "thorn", mapStar(cx, cy, r * s, 12, 0.48, (n) => rnd(n + k * 13), rnd(20 + k) * 3));
      });
    },
    plains(add, x, y, s, rnd, few) {
      if (few) { if (rnd(1) < 0.6) mapTuft(add, x + (0.3 + rnd(2) * 0.4) * s, y + (0.55 + rnd(3) * 0.35) * s, s * 0.5, "tuftDry"); return; }
      [[0.28, 0.42], [0.7, 0.36], [0.5, 0.78], [0.18, 0.88], [0.84, 0.8]].forEach(([u, v], k) => { if (k < 2 || rnd(k) < 0.6) mapTuft(add, x + (u + (rnd(5 + k) - 0.5) * 0.12) * s, y + (v + (rnd(10 + k) - 0.5) * 0.1) * s, s * 0.12, "tuftDry"); });
    },
    pine(add, x, y, s, rnd, few) { MAP_ART.fantasy.forest(add, x, y, s, rnd, few, true); },
    jungle(add, x, y, s, rnd, few) {
      const tree = (px, base, d, k) => { if (rnd(40 + k) < 0.3) mapPalm(add, px, base, d); else mapTree(add, px, base, d, "jungle"); };
      if (few) { tree(x + (0.5 + (rnd(2) - 0.5) * 0.3) * s, y + (0.96 + (rnd(3) - 0.5) * 0.2) * s, s * (0.95 + rnd(4) * 0.25), 0); return; }
      [[0.2, 0.36], [0.56, 0.3], [0.84, 0.44], [0.36, 0.64], [0.7, 0.7], [0.16, 0.94], [0.5, 0.96], [0.86, 0.96]].forEach(([u, v], k) => tree(x + (u + (rnd(k) - 0.5) * 0.1) * s, y + (v + (rnd(10 + k) - 0.5) * 0.08) * s, s * (0.3 + rnd(30 + k) * 0.08), k));
    },
    desert(add, x, y, s, rnd, few) {
      const dune = (cx, cy, w) => add(cy, "dune", `M${mapPt([cx - w / 2, cy])}Q${mapPt([cx - w * 0.1, cy - w * 0.32])} ${mapPt([cx + w / 2, cy - w * 0.04])}`);
      if (few) { if (rnd(1) < 0.6) dune(x + (0.35 + rnd(2) * 0.3) * s, y + (0.45 + rnd(3) * 0.35) * s, s * 1.3); return; }
      [[0.3, 0.34, 0.42], [0.68, 0.56, 0.48], [0.36, 0.86, 0.4]].forEach(([u, v, w], k) => dune(x + (u + (rnd(k) - 0.5) * 0.12) * s, y + (v + (rnd(10 + k) - 0.5) * 0.08) * s, s * w));
    },
    tundra(add, x, y, s, rnd, few) {
      if (few) { if (rnd(1) < 0.55) mapTuft(add, x + (0.3 + rnd(2) * 0.4) * s, y + (0.55 + rnd(3) * 0.35) * s, s * 0.4, "tuftCold"); return; }
      [[0.3, 0.4], [0.72, 0.6], [0.4, 0.88]].forEach(([u, v], k) => { if (k === 0 || rnd(k) < 0.6) mapTuft(add, x + (u + (rnd(5 + k) - 0.5) * 0.14) * s, y + (v + (rnd(10 + k) - 0.5) * 0.1) * s, s * 0.1, "tuftCold"); });
      const cx = x + (0.6 + rnd(20) * 0.2) * s, cy = y + (0.24 + rnd(21) * 0.1) * s, w = s * 0.12;
      add(cy, "drift", `M${mapPt([cx - w, cy])}a${mapNum(w)} ${mapNum(w * 0.42)} 0 1 0 ${mapNum(2 * w)} 0a${mapNum(w)} ${mapNum(w * 0.42)} 0 1 0 ${mapNum(-2 * w)} 0Z`);
    },
    ice(add, x, y, s, rnd, few) {
      const ridge = (cx, cy, w) => add(cy, "ridge", mapLine([[cx - w / 2, cy], [cx - w * 0.2, cy - w * 0.16], [cx + w * 0.05, cy - w * 0.02], [cx + w * 0.3, cy - w * 0.2], [cx + w / 2, cy]]));
      if (few) { if (rnd(1) < 0.6) ridge(x + (0.35 + rnd(2) * 0.3) * s, y + (0.45 + rnd(3) * 0.35) * s, s * 1.2); return; }
      [[0.32, 0.34, 0.4], [0.7, 0.58, 0.44], [0.38, 0.86, 0.36]].forEach(([u, v, w], k) => ridge(x + (u + (rnd(k) - 0.5) * 0.12) * s, y + (v + (rnd(10 + k) - 0.5) * 0.08) * s, s * w));
    },
    swamp(add, x, y, s, rnd, few) {
      const reeds = (cx, base, h) => add(base, "reed", mapLine([[cx, base], [cx - h * 0.25, base - h]]) + mapLine([[cx, base], [cx + h * 0.05, base - h * 1.15]]) + mapLine([[cx, base], [cx + h * 0.32, base - h * 0.85]]));
      const water = (cx, cy, w) => add(cy, "marsh", mapLine([[cx - w / 2, cy], [cx + w / 2, cy]]));
      if (few) { if (rnd(1) < 0.6) { const cx = x + (0.35 + rnd(2) * 0.3) * s, cy = y + (0.55 + rnd(3) * 0.3) * s; reeds(cx, cy, s * 0.6); water(cx + s * 0.2, cy + s * 0.12, s * 0.7); } return; }
      [[0.3, 0.4], [0.7, 0.72]].forEach(([u, v], k) => { const cx = x + (u + (rnd(k) - 0.5) * 0.12) * s, cy = y + (v + (rnd(5 + k) - 0.5) * 0.1) * s; reeds(cx, cy, s * 0.16); water(cx + s * 0.1, cy + s * 0.05, s * 0.26); water(cx + s * 0.16, cy + s * 0.11, s * 0.16); });
    },
  },
  // The battle grid, seen from above. Each ground: its three tones, then how likely a square of it is to carry each
  // thing (blade = grass, pebble, flower, rock = a boulder, slab and crack = bare stone, bush, thorn, block = a cut
  // stone, cobble, streak = a wheel mark, puddle, mist, root, wave, reed, ripple = blown sand, frost = a crack in
  // ice, drift = a patch of snow, tree and big = a trunk under its crown; needle = its trees are pines; plank = the
  // boards of a bridge, laid across the road).
  top: {
    sea:       { tones: ["#6FA3B7", "#6CA0B4", "#72A6BA"], wave: 0.8 },
    water:     { tones: ["#8FBFC9", "#8CBCC6", "#92C2CC"], wave: 0.25, pebble: 0.06 },
    deep:      { tones: ["#5C93A8", "#5990A5", "#5F96AB"], wave: 0.5 },
    land:      { tones: ["#93B262", "#90AF5F", "#96B565"], blade: 0.75, flower: 0.07, pebble: 0.08, bush: 0.02 },
    forest:    { tones: ["#6F8F4A", "#6C8C47", "#72924D"], blade: 0.5, bush: 0.11, tree: 0.04, big: 0.013, pebble: 0.04 },
    hills:     { tones: ["#A9AE6A", "#A6AB67", "#ACB16D"], blade: 0.5, rock: 0.14, pebble: 0.3 },
    mountains: { tones: ["#A29C91", "#9E988D", "#A6A095"], crack: 0.5, slab: 0.4, rock: 0.22, pebble: 0.45 },
    village:   { tones: ["#CBB78C", "#C8B489", "#CEBA8F"], cobble: 0.45, pebble: 0.2, blade: 0.08 },
    town:      { tones: ["#C8B48A", "#C5B187", "#CBB78D"], cobble: 0.6, pebble: 0.16, blade: 0.05 },
    city:      { tones: ["#C3B69E", "#C0B39B", "#C6B9A1"], cobble: 0.85, pebble: 0.1, block: 0.03 },
    great_city: { tones: ["#BEB4A0", "#BBB19D", "#C1B7A3"], cobble: 0.9, pebble: 0.08, block: 0.05 },
    road:      { tones: ["#B99C6C", "#B69969", "#BC9F6F"], streak: 0.7, pebble: 0.25 },
    // a bridge (step 11): the road carried over the water on planks laid across it; a ford: knee-deep water over gravel
    // and flat stones, a little stiller than the river round it
    bridge:    { tones: ["#9C7A4E", "#99774B", "#9F7D51"], plank: true },
    ford:      { tones: ["#A4C6C4", "#A1C3C1", "#A7C9C7"], wave: 0.3, pebble: 0.55, slab: 0.12 },
    pass:      { tones: ["#ABA08A", "#A89D87", "#AEA38D"], streak: 0.45, pebble: 0.45, crack: 0.12, rock: 0.04 },
    ruins:     { tones: ["#AEAA6E", "#ABA76B", "#B1AD71"], block: 0.17, pebble: 0.3, blade: 0.45 },
    valley:    { tones: ["#86B45C", "#83B159", "#89B75F"], blade: 0.85, flower: 0.32 },
    fog:       { tones: ["#94A18B", "#919E88", "#97A48E"], puddle: 0.22, mist: 0.36, blade: 0.25 },
    thorns:    { tones: ["#A09E60", "#9D9B5D", "#A3A163"], thorn: 0.45, blade: 0.3, pebble: 0.1 },
    lair:      { tones: ["#55683F", "#52653C", "#586B42"], root: 0.4, thorn: 0.14, tree: 0.05, big: 0.02, gloom: true },
    plains:    { tones: ["#C4BA6A", "#C1B767", "#C7BD6D"], blade: 0.95, flower: 0.06, pebble: 0.04 },
    pine:      { tones: ["#5E7A4E", "#5B774B", "#617D51"], blade: 0.2, pebble: 0.06, tree: 0.12, big: 0.01, needle: true },
    jungle:    { tones: ["#4E7A38", "#4B7735", "#517D3B"], blade: 0.3, bush: 0.3, root: 0.12, tree: 0.2, big: 0.015 },
    desert:    { tones: ["#E4C17D", "#E1BE7A", "#E7C480"], ripple: 0.45, pebble: 0.08, rock: 0.02 },
    tundra:    { tones: ["#A7AE93", "#A4AB90", "#AAB196"], blade: 0.22, pebble: 0.3, bush: 0.03, drift: 0.08, rock: 0.04 },
    ice:       { tones: ["#E6EDF0", "#E3EAED", "#E9F0F3"], frost: 0.3, drift: 0.12 },
    swamp:     { tones: ["#7B8A5B", "#788758", "#7E8D5E"], puddle: 0.38, reed: 0.5, blade: 0.3, root: 0.06, mist: 0.06 },
    plain:     { tones: ["#93B262", "#90AF5F", "#96B565"] },
  },
  // The strokes of the battle grid, in the order they are painted.
  paint: [
    { k: "blade", line: "#5E7E39", w: 1 }, { k: "streak", line: "#927952", w: 1.6 }, { k: "wave", line: "#CFE6EC", w: 1.4 }, { k: "crack", line: "#6F6A62", w: 1 },
    { k: "plank", line: "#5E4426", w: 1 }, { k: "plankLit", line: "#C9A66E", w: 0.8, o: 0.6 },
    { k: "reed", line: "#4E5D2B", w: 1.1 }, { k: "ripple", line: "#B49C67", w: 1.3 }, { k: "frost", line: "#AFC5D1", w: 1.2 },
    { k: "puddle", fill: "#8AA6AD", line: "#B9CDD0", w: 1 }, { k: "root", line: "#4E3B29", w: 2.6 }, { k: "drift", fill: "#FAFBFB", line: "#D5E0E5", w: 0.8 },
    { k: "pebble", fill: "#9B958A" }, { k: "slab", fill: "#B9B4A9" }, { k: "petal", fill: "#F6F2DC" }, { k: "gold", fill: "#E6C552" },
    { k: "shade", fill: "#000000", o: 0.2 },
    { k: "rock", fill: "#A9A398", line: "#69645C", w: 1 }, { k: "rockLit", fill: "#CBC6BC" },
    { k: "block", fill: "#D2CBBB", line: "#7B7568", w: 1 }, { k: "cobble", fill: "#C6B797", line: "#A08E6C", w: 0.8 },
    { k: "bush", fill: "#5F8B40", line: "#456A2E", w: 1 }, { k: "bushLit", fill: "#81A856" },
    { k: "thorn", fill: "#59652F", line: "#3D4621", w: 1 }, { k: "thornLit", fill: "#7F8B46" },
    { k: "trunk", fill: "#6B4A2E", line: "#44301C", w: 1.2 },
    { k: "leafDark", fill: "#3E6A32", o: 0.7 }, { k: "leaf", fill: "#5B8D44", o: 0.72 }, { k: "leafLit", fill: "#88B465", o: 0.6 },
    { k: "gloomDark", fill: "#2C4A27", o: 0.74 }, { k: "gloom", fill: "#40662F", o: 0.74 }, { k: "gloomLit", fill: "#5F8744", o: 0.55 },
    { k: "needleDark", fill: "#2E4A2B", o: 0.78 }, { k: "needle", fill: "#41633A", o: 0.78 }, { k: "needleLit", fill: "#6A8C55", o: 0.6 },
    { k: "mist", line: "#FFFFFF", w: 5, o: 0.4 },
  ],
};
// A color part of the way from one color to another (both "#RRGGBB"; t = 0 the first, 1 the second).
const mapMix = (a, b, t) => "#" + [1, 3, 5].map(n => Math.round(parseInt(a.slice(n, n + 2), 16) * (1 - t) + parseInt(b.slice(n, n + 2), 16) * t).toString(16).padStart(2, "0")).join("");
// The color of a ground on the fantasy map: the paper tinted with the color that ground has on the battle grid
// (MAP_ART.top), so a cell and the squares inside it are one color family at every level. A ground the battle grid
// has no look of its own for is open land.
const mapWash = (what) => (what === "sea" || what === "deep" ? MAP_PAPER.sea : what === "water" ? mapMix(MAP_PAPER.shallow, MAP_PAPER.sea, 0.45) : mapMix(MAP_PAPER.land, (MAP_ART.top[what] || MAP_ART.top.land).tones[0], MAP_TINT));
// Water on the map: rivers and lakes, waded or swum (rpg_map_water); a ford is knee-deep water (step 11)
const mapWet = (k) => k === "water" || k === "deep" || k === "ford";
// Harder ground drawn darker (Peter 2026-10-03: thicker forest, deeper water darker): h(i, j) = how hard a square is
// inside its ground, 0 to 9 (rpg_map_view: cells' hard, detail.hard), nothing when not known. Each step from 2 up adds
// a thin dark wash over the squares at or above it, so 9 (a thicket) is the darkest; deep water is shaded in blue.
function mapHardShade(cols, rows, h, unit, round, color = "#1F2A12", wob) {
  const out = [];
  let any = false;
  for (let j = 0; j < rows && !any; j++) for (let i = 0; i < cols; i++) if (h(i, j) != null) { any = true; break; }
  if (!any) return out;
  for (let d = 2; d <= 9; d++) out.push({ d: mapOutline(cols, rows, (i, j) => { const v = h(i, j); return v != null && v >= d; }, unit, round, wob), fill: color, o: 0.045 });
  return out.filter(l => l.d);
}
// Where to set a symbol s wide near x, y so it does not cover one already set: at x, y when that is free, else the
// first free spot on the rings round it, one symbol apart. The same symbols in the same order always land the same.
function mapAside() {
  const placed = [];
  const free = (x, y, s) => placed.every(([px, py, ps]) => Math.hypot(px - x, py - y) >= (ps + s) * 0.5);
  return (x, y, s) => {
    let at = [x, y];
    if (!free(x, y, s)) {
      search: for (let ring = 1; ring <= 3; ring++) for (let a = 0; a < 8; a++) {
        const t = (a + ring * 0.5) * Math.PI / 4, px = x + Math.cos(t) * s * ring, py = y + Math.sin(t) * s * ring;
        if (free(px, py, s)) { at = [px, py]; break search; }
      }
    }
    placed.push([at[0], at[1], s]);
    return at;
  };
}
// One grid in the fantasy style: the strokes to paint, bottom first, and the names to write.
function mapFantasy(v, byId) {
  const level = Number(v.level) || 1, cols = Number(v.cols) || 12, rows = Number(v.rows) || 12;
  const cells = Array.isArray(v.cells) ? v.cells : [];
  const places = Array.isArray(v.places) ? v.places : [];
  const detail = v.detail && Array.isArray(v.detail.cells) ? v.detail : null;
  const m = /^(\d+)-(\d+)-(\d+)$/.exec(v.view || "");
  // The squares being drawn: the world and a place shown whole draw the finer cells of their detail, every other
  // grid its own cells. sub = squares drawn across one cell of the grid.
  const C = detail ? Number(detail.cols) || cols : cols, R = detail ? Number(detail.rows) || rows : rows;
  const unit = cols * 100 / C;
  const sub = C / cols;
  const lvl = detail ? level + 1 : level;
  // where the first square drawn sits in the world (v.origin: the first cell of the grid)
  const origin = Array.isArray(v.origin) ? v.origin.map(Number) : null;
  const x0 = origin ? origin[0] * sub : m ? Number(m[2]) * cols : 0, y0 = origin ? origin[1] * sub : m ? Number(m[3]) * rows : 0;
  // the world's east edge meets its west edge; a place shown whole stops at its own edges
  const wrap = !!detail && detail.wrap !== false;
  const grid = new Array(C * R).fill(null);
  if (detail) {
    const kinds = Object.fromEntries(MAP_GROUNDS.map(([k, ch]) => [ch.charCodeAt(0), k]).concat([["?".charCodeAt(0), "unknown"]]));
    // the smaller places reaching into a square of the detail, by "i,j" from the top-left corner
    const marks = detail.marks && typeof detail.marks === "object" ? detail.marks : {};
    // how hard each square is inside its ground, one digit a square (detail.hard; - for none)
    const hard = Array.isArray(detail.hard) ? detail.hard : [];
    // the rivers drawn as lines, one digit a square (detail.rivers; 0 for none), and where in the square the river's
    // line runs (detail.river_x, river_y: 0 the west or north edge to 9 the east or south edge)
    const rivers = Array.isArray(detail.rivers) ? detail.rivers : [];
    const rxs = Array.isArray(detail.river_x) ? detail.river_x : [], rys = Array.isArray(detail.river_y) ? detail.river_y : [];
    const at9 = (list, i, j) => (Number(String(list[j] || "").charAt(i)) || 0) / 9 - 0.5;
    detail.cells.forEach((row, j) => { for (let i = 0; i < C; i++) { const code = String(row || "").charCodeAt(i); const mk = marks[i + "," + j]; const hd = String(hard[j] || "").charAt(i); const rv = Number(String(rivers[j] || "").charAt(i)) || 0; grid[j * C + i] = { ...(kinds[code] ? { k: kinds[code] } : { k: "place", id: (detail.places || [])[code - 256] }), marks: Array.isArray(mk) ? mk : [], h: hd >= "0" && hd <= "9" ? Number(hd) : null, rv, rx: rv ? at9(rxs, i, j) : 0, ry: rv ? at9(rys, i, j) : 0 }; } });
  } else {
    // a cell's river: [its size, where its line runs from the cell's middle in thousandths of a cell, east, south]
    cells.forEach(c => { const r = Array.isArray(c.river) ? c.river : null; grid[(c.y - 1) * C + (c.x - 1)] = { k: c.kind, id: c.place || null, marks: Array.isArray(c.marks) ? c.marks : [], h: c.hard == null ? null : Number(c.hard), rv: r ? Number(r[0]) || 0 : 0, rx: r ? (Number(r[1]) || 0) / 1000 : 0, ry: r ? (Number(r[2]) || 0) / 1000 : 0 }; });
  }
  const none = { k: "sea" };
  const get = (i, j) => grid[(j < 0 ? 0 : j >= R ? R - 1 : j) * C + (wrap ? ((i % C) + C) % C : (i < 0 ? 0 : i >= C ? C - 1 : i))] || none;
  const layers = [{ d: `M0 0H${cols * 100}V${rows * 100}H0Z`, fill: MAP_PAPER.sea }];
  // every edge on this map is drawn soft and wandering (mapOutline wob), steady for each spot of the world
  const wob = { lvl, x0, y0 };
  const land = mapOutline(C, R, (i, j) => { const k = get(i, j).k; return k !== "sea" && k !== "unknown"; }, unit, 0.45, wob);
  // the land is open land (grass) from coast to coast; every other ground is painted over it in its own color
  layers.push({ d: land, line: MAP_PAPER.shallow, units: unit * (detail ? 1.5 : 0.4) }, { d: land, line: MAP_PAPER.shore, units: unit * (detail ? 0.7 : 0.2) }, { d: land, fill: mapWash("land") });
  // what ground a cell shows: a place's symbol names it, else the kind of the cell
  const shows = (g) => { const p = g.k === "place" ? byId[g.id] : null; return p ? p.icon : g.k; };
  const grounds = new Set();
  grid.forEach(g => { const what = g ? shows(g) : null; if (what && what !== "sea" && what !== "land" && what !== "unknown" && MAP_ART.top[what]) grounds.add(what); });
  // each ground, then a soft edge of its own color along its outline, half a cell wide, so where two grounds meet
  // each fades a little into the other (open land too); kept on the land
  const soft = [];
  grounds.forEach(what => { const d = mapOutline(C, R, (i, j) => shows(get(i, j)) === what, unit, 0.45, wob); layers.push({ d, fill: mapWash(what) }); soft.push({ d, line: mapWash(what), units: unit * 0.5, o: 0.4, clip: land }); });
  if (soft.length) soft.push({ d: mapOutline(C, R, (i, j) => shows(get(i, j)) === "land", unit, 0.45, wob), line: mapWash("land"), units: unit * 0.5, o: 0.4, clip: land });
  layers.push(...soft.filter(l => l.d));
  // every place with ground of its own on this grid: a wash of its color under its symbols
  const filled = new Map();
  grid.forEach((g, n) => { if (g && g.k === "place" && g.id) { if (!filled.has(g.id)) filled.set(g.id, []); filled.get(g.id).push(n); } });
  filled.forEach((list, id) => { const p = byId[id]; if (p && p.color) layers.push({ d: mapOutline(C, R, (i, j) => { const g = get(i, j); return g.k === "place" && g.id === id; }, unit, 0.45, wob), fill: p.color, o: 0.3 }); });
  // harder ground is darker: each square a shade by how hard it is inside its ground (0 to 9; thickets 9); deeper
  // water darker blue
  layers.push(...mapHardShade(C, R, (i, j) => (mapWet(get(i, j).k) ? null : get(i, j).h), unit, 0.45, undefined, wob));
  layers.push(...mapHardShade(C, R, (i, j) => (mapWet(get(i, j).k) ? get(i, j).h : null), unit, 0.45, "#123A5A", wob));
  // rivers too narrow for this grid's cells: a line through the point of each cell where the river truly runs, so it
  // lies where the next zoom shows it; thinner for smaller rivers; a diagonal step only where no straight one joins the
  // two and never across a corner of sea; a scrap of fewer than three cells that does not run off the grid is left out
  const runs = {};
  const flow = (i, j) => (i >= 0 && j >= 0 && i < C && j < R && grid[j * C + i] && grid[j * C + i].rv > 0 ? grid[j * C + i].rv : 0);
  const wet = (i, j) => { const k = get(i, j).k; return k === "sea" || k === "unknown"; };
  const pt = (i, j) => { const g = grid[j * C + i]; return [(i + 0.5 + g.rx) * unit, (j + 0.5 + g.ry) * unit]; };
  const links = (i, j) => {
    const to = [[1, 0], [0, 1], [-1, 0], [0, -1]].filter(([a, b]) => flow(i + a, j + b));
    [[1, 1], [-1, 1], [1, -1], [-1, -1]].forEach(([a, b]) => { if (flow(i + a, j + b) && !flow(i + a, j) && !flow(i, j + b) && !wet(i + a, j) && !wet(i, j + b)) to.push([a, b]); });
    return to;
  };
  const seen = new Set(), keep = new Set();
  for (let j = 0; j < R; j++) for (let i = 0; i < C; i++) {
    if (!flow(i, j) || seen.has(j * C + i)) continue;
    const part = [], todo = [[i, j]];
    seen.add(j * C + i);
    while (todo.length) { const [a, b] = todo.pop(); part.push([a, b]); links(a, b).forEach(([da, db]) => { const n = (b + db) * C + a + da; if (!seen.has(n)) { seen.add(n); todo.push([a + da, b + db]); } }); }
    if (part.length >= 3 || part.some(([a, b]) => a === 0 || b === 0 || a === C - 1 || b === R - 1)) part.forEach(([a, b]) => keep.add(b * C + a));
  }
  // rivers branch but never loop: where cells of river lie side by side (two lines close together, or a bend that
  // fills a block of cells) only the joins that link pieces not yet linked are drawn, the same river's first, the
  // shortest first, so no little squares or triangles of river appear
  const joins = [];
  for (let j = 0; j < R; j++) for (let i = 0; i < C; i++) {
    const k = flow(i, j);
    if (!k || !keep.has(j * C + i)) continue;
    links(i, j).filter(([a, b]) => b > 0 || (b === 0 && a > 0)).forEach(([a, b]) => {
      const p = pt(i, j), q = pt(i + a, j + b), other = flow(i + a, j + b);
      joins.push({ from: j * C + i, to: (j + b) * C + i + a, p, q, w: Math.max(k, other), rank: (other === k ? 0 : 1e6) + Math.hypot(q[0] - p[0], q[1] - p[1]) });
    });
  }
  const root = new Map();
  const top = (n) => { let r = n; while (root.has(r) && root.get(r) !== r) r = root.get(r); root.set(n, r); return r; };
  // the joins kept, by the width they are drawn in, as the neighbours of each cell
  const kept = {};
  joins.sort((a, b) => a.rank - b.rank).forEach(e => {
    const a = top(e.from), b = top(e.to);
    if (a === b) return;
    root.set(a, b);
    const near = kept[e.w] || (kept[e.w] = new Map());
    [[e.from, e.to, e.p, e.q], [e.to, e.from, e.q, e.p]].forEach(([n, m, p, q]) => { if (!near.has(n)) near.set(n, { at: p, to: [] }); near.get(n).to.push([m, q]); });
  });
  // each river is drawn as one smooth line from end to end (step 10a, Peter 2026-10-04: rivers are squiggly lines):
  // its cells' points steer the line, which runs through the midpoint between each pair of them, so the bends the
  // cells hold show as curves and not as corners; a line ends where a river ends or meets another
  Object.keys(kept).forEach(w => {
    const near = kept[w];
    const used = new Set();
    const edge = (n, m) => (n < m ? n + "-" + m : m + "-" + n);
    near.forEach((node, n) => {
      if (node.to.length === 2) return;
      node.to.forEach(([m0]) => {
        if (used.has(edge(n, m0))) return;
        const chain = [node.at];
        let from = n, at = m0;
        while (true) {
          used.add(edge(from, at));
          const here = near.get(at);
          chain.push(here.at);
          if (here.to.length !== 2) break;
          const next = here.to.find(([m]) => m !== from);
          if (!next || used.has(edge(at, next[0]))) break;
          from = at; at = next[0];
        }
        runs[w] = (runs[w] || "") + mapBend(chain);
      });
    });
  });
  Object.keys(runs).sort().reverse().forEach(k => layers.push({ d: runs[k], line: MAP_RIVER, w: MAP_RIVER_W[k] || 1 }));
  layers.push({ d: land, line: MAP_INK, w: 1.25 });
  const strokes = mapRows(unit * (detail ? 1 : 0.12));
  const marked = mapRows(unit * 0.12);
  const pads = [], lanes = [], lands = [], blocks = [], ways = [];
  const names = [];
  // the landmarks the kids login sees from far in ground not found yet (step 12b), drawn over the dark
  const far = mapRows(unit * 0.12), farPads = [];
  const roads = new Map();
  const road = (id, n, full) => { if (!roads.has(id)) roads.set(id, { cells: new Set(), full }); roads.get(id).cells.add(n); };
  const aside = mapAside();
  for (let j = 0; j < R; j++) for (let i = 0; i < C; i++) {
    const g = grid[j * C + i];
    if (!g) continue;
    const rnd = (n) => mapRand(lvl, x0 + i, y0 + j, n);
    const p = g.k === "place" ? byId[g.id] : null;
    const what = shows(g);
    if (what === "road") road(g.id, j * C + i, true);
    else if (MAP_ART.fantasy[what]) MAP_ART.fantasy[what](strokes.add, i * unit, j * unit, unit, rnd, !!detail);
    // the smaller places in this cell: a road runs through it; any other is drawn once, in the cell its center is in
    const marks = (g.marks || []).map(id => byId[id]).filter(Boolean);
    marks.filter(k => k.icon === "road").forEach(k => road(k.id, j * C + i, false));
    const here = marks.filter(k => k.icon !== "road" && Array.isArray(k.spot) && Math.floor(k.spot[0] * sub / 1000) === i && Math.floor(k.spot[1] * sub / 1000) === j);
    if (here.length > 3) {
      pads.push({ d: mapCircle((i + 0.5) * unit, (j + 0.5) * unit, detail ? 12 : unit * 0.26), fill: MAP_INK });
      names.push({ text: String(here.length), x: (i + 0.5) * unit, y: (j + 0.5) * unit, count: true });
    } else {
      // a grid drawn fine puts each smaller place at its own middle, a twentieth of the long side of the map wide,
      // stepping round any it would cover (mapAside); any other grid sets them side by side in their cell
      const s = detail ? Math.max(cols, rows) * 5 : unit * [0, 0.62, 0.46, 0.42][here.length];
      const spots = [[], [[0.5, 0.5]], [[0.27, 0.5], [0.73, 0.5]], [[0.27, 0.29], [0.73, 0.29], [0.5, 0.73]]][here.length];
      here.forEach((k, n) => {
        const sk = s * (MAP_MARK_SIZE[k.icon] || 1) * mapMarkScale(k);
        const [cx, cy] = detail ? aside(k.spot[0] / 10, k.spot[1] / 10, sk) : [(i + spots[n][0]) * unit, (j + spots[n][1]) * unit];
        // a landmark on busy ground (a mountain range, a wood) sits on a softer disc of paper so it stands clear of it
        const dark = g.k === "unknown", busy = k.landmark && MAP_BUSY.includes(g.k);
        if (p || dark || busy) (dark ? farPads : pads).push({ d: mapCircle(cx, cy, sk * 0.56), fill: MAP_PAPER.land, o: dark ? 0.9 : busy && !p ? 0.62 : 0.82 });
        if (MAP_ART.fantasy[k.icon]) MAP_ART.fantasy[k.icon](dark ? far.add : marked.add, cx - sk / 2, cy - sk / 2, sk, (q) => mapRand(lvl, x0 + i, y0 + j, q + 100 * (n + 1)), true);
        else pads.push({ d: mapCircle(cx, cy, sk * 0.2), fill: k.color || MAP_INK, line: MAP_INK, w: 1 });
        blocks.push([cx - sk / 2, cy - sk / 2, cx + sk / 2, cy + sk / 2]);
        names.push({ text: k.name, x: cx, y: cy, r: sk / 2, size: MAP_MARK_TEXT[k.icon] || 11.5 });
      });
    }
  }
  // a road: one line through the cells it runs through, out to the edge of the grid where it runs off it
  roads.forEach((r, id) => {
    let d = "";
    const has = (i, j) => i >= 0 && j >= 0 && i < C && j < R && r.cells.has(j * C + i);
    const list = Array.from(r.cells).sort((a, b) => a - b);
    list.forEach(n => {
      const i = n % C, j = Math.floor(n / C), cx = (i + 0.5) * unit, cy = (j + 0.5) * unit;
      const e = has(i + 1, j), w = has(i - 1, j), s = has(i, j + 1), u = has(i, j - 1);
      if (e) d += mapLine([[cx, cy], [cx + unit, cy]]);
      if (s) d += mapLine([[cx, cy], [cx, cy + unit]]);
      if (!e && !w && !s && !u) d += mapLine([[cx - unit * 0.35, cy], [cx + unit * 0.35, cy]]);
      if (i === 0 && e) d += mapLine([[0, cy], [cx, cy]]);
      if (i === C - 1 && w) d += mapLine([[cx, cy], [C * unit, cy]]);
      if (j === 0 && s) d += mapLine([[cx, 0], [cx, cy]]);
      if (j === R - 1 && u) d += mapLine([[cx, cy], [cx, R * unit]]);
    });
    if (r.full) lanes.push({ d, line: MAP_INK, units: unit * 0.3, cap: "butt" }, { d, line: "#D9BF8C", units: unit * 0.3, inset: 2.4, cap: "butt" });
    else lanes.push({ d, line: MAP_PAPER.land, w: 3.4 }, { d, line: "#7A5A3A", w: 1.6, dash: [5, 3.5] });
    const mid = list[Math.floor(list.length / 2)];
    if (byId[id] && mid !== undefined) ways.push({ text: byId[id].name, x: (mid % C + 0.5) * unit, y: (Math.floor(mid / C) + 0.5) * unit, r: unit * (r.full ? 0.2 : 0.1), size: 11.5, way: unit * 2.5 });
  });
  // the roads between places (rpg_map_view: roads, step 8b): each piece [size, x0, y0, x1, y1, x2, y2, ...] the points
  // of a road's wandering line (step 10b) in thousandths of a cell, drawn as one smooth line through them (mapBend), as
  // wide as the road truly is where that is wider than a line (road_width, thousandths of a cell of what is drawn):
  // a highway two inked edges with the road light between, a road one brown line, a lane a dashed one; drawn close,
  // each is a light road between its edges
  const rw = Array.isArray(v.road_width) ? v.road_width.map(Number) : [];
  const paths = { 1: "", 2: "", 3: "" };
  (Array.isArray(v.roads) ? v.roads : []).forEach(r => {
    if (!Array.isArray(r) || paths[r[0]] === undefined) return;
    const pts = [];
    for (let k = 1; k + 1 < r.length; k += 2) pts.push([r[k] / 10, r[k + 1] / 10]);
    if (pts.length >= 2) paths[r[0]] += mapBend(pts);
  });
  const wide = (k) => (rw[k - 1] || 0) / 1000 * unit;
  const roadways = [];
  MAP_ROADS.forEach(({ k, edge, mid }) => { if (paths[k]) roadways.push({ d: paths[k], line: edge.line, units: wide(k), min: edge.min, dash: edge.dash, cap: edge.dash ? "butt" : "round" }); });
  MAP_ROADS.forEach(({ k, edge, mid }) => { if (paths[k]) roadways.push({ d: paths[k], line: mid.line, units: wide(k), inset: mid.inset, min: mid.min }); });
  // the bridges and fords (step 11; rpg_map_view: crossings): each [kind, river, road, x, y, angle, span], x and y in
  // thousandths of a cell, angle the way across the water (degrees, clockwise from east), span the width of the water
  // there; drawn a little longer than the water is wide, and never too small to see
  const crossings = [];
  (Array.isArray(v.crossings) ? v.crossings : []).forEach(c => {
    if (!Array.isArray(c) || c.length < 7) return;
    const kind = Number(c[0]), rc = Number(c[2]), x = c[3] / 10, y = c[4] / 10, a = Number(c[5]) * Math.PI / 180, span = c[6] / 10;
    const L = Math.max(span + unit * (kind === 1 ? 0.16 : 0.1), unit * 0.22, cols * 1.8);
    crossings.push(...mapCrossing(x, y, a, L, kind, wide(rc) || 0));
  });
  // the names of the lands this grid lists (continents on the world, countries on a continent), spread to their size
  places.filter(p => p.listed && !p.ground && Array.isArray(p.spot)).forEach(p => {
    lands.push({ text: String(p.name || "").toUpperCase(), x: p.spot[0] / 10, y: p.spot[1] / 10, caps: true, room: (p.spot[2] || 0) / 10, must: true });
  });
  // the name of each place with ground here, at the middle of its cells
  filled.forEach((list, id) => {
    const p = byId[id];
    if (!p || p.icon === "road") return;
    const sx = list.reduce((t, n) => t + n % C, 0) / list.length, sy = list.reduce((t, n) => t + Math.floor(n / C), 0) / list.length;
    if (list.length > 2) lands.push({ text: p.name, x: (sx + 0.5) * unit, y: (sy + 0.5) * unit, size: 13, must: true, mid: true });
    else lands.push({ text: p.name, x: (sx + 0.5) * unit, y: (sy + 0.5) * unit, r: unit * 0.5, size: 12.5, must: true });
  });
  // a compass rose in the first corner that is open sea
  const rose = [];
  // on a place shown whole the rose shrinks with the grid (the world is 12 by 6 cells)
  const fit = detail ? Math.min(1, Math.sqrt(cols * rows / 72)) : 1;
  const reach = (detail ? 0.62 : 1.02) * fit, edge = (detail ? 0.72 : 1.1) * fit;
  const corner = [[cols - edge, rows - edge], [edge, rows - edge], [cols - edge, edge], [edge, edge]].find(([cx, cy]) => {
    for (let j = Math.floor((cy - reach) * 100 / unit); j <= Math.floor((cy + reach) * 100 / unit - 0.001); j++) for (let i = Math.floor((cx - reach) * 100 / unit); i <= Math.floor((cx + reach) * 100 / unit - 0.001); i++) if (i < 0 || j < 0 || i >= C || j >= R || (grid[j * C + i] || none).k !== "sea") return false;
    return true;
  });
  if (corner) {
    const cx = corner[0] * 100, cy = corner[1] * 100, r = reach * 62;
    const point = (a, len, wd, side) => mapPoly([[cx + Math.cos(a) * len, cy + Math.sin(a) * len], [cx + Math.cos(a + side * Math.PI / 2) * wd, cy + Math.sin(a + side * Math.PI / 2) * wd], [cx, cy]]);
    let light = "", dark = "";
    for (let k = 0; k < 8; k++) { const a = k * Math.PI / 4 - Math.PI / 2, len = r * (k % 2 ? 0.52 : 1), wd = r * (k % 2 ? 0.13 : 0.17); light += point(a, len, wd, -1); dark += point(a, len, wd, 1); }
    rose.push({ d: mapCircle(cx, cy, r * 0.66), line: MAP_INK, w: 0.9, o: 0.7 }, { d: light, fill: MAP_PAPER.land, line: MAP_INK, w: 0.8 }, { d: dark, fill: "#7A6A55", line: MAP_INK, w: 0.8 });
    lands.push({ text: "N", x: cx, y: cy - r * 1.22, north: true, size: r * 0.36 });
  }
  const lines = [];
  for (let i = 1; i < cols; i++) lines.push(mapLine([[i * 100, 0], [i * 100, rows * 100]]));
  for (let j = 1; j < rows; j++) lines.push(mapLine([[0, j * 100], [cols * 100, j * 100]]));
  // what the group has not found yet: the dark over it
  const fog = mapFog(C, R, unit, (i, j) => get(i, j).k === "unknown", 0.45, cols, rows, lvl, x0, y0);
  return {
    wide: cols * 100, high: rows * 100, unit, aged: true,
    layers: layers.concat(rose, strokes.list(MAP_ART.ink), roadways, lanes, crossings, pads, marked.list(MAP_ART.ink), [{ d: lines.join(""), line: MAP_INK, w: 0.8, o: 0.16 }], fog, farPads, far.list(MAP_ART.ink)),
    names: lands.concat(names, ways), blocks,
  };
}
// A smooth wandering number for a spot of the world (x, y in squares, any fraction), steady from one look to the
// next: steady rolls at the corners of a lattice `size` squares wide, eased between them; about -0.5 to 0.5.
const mapWander = (x, y, size, n) => {
  const gx = Math.floor(x / size), gy = Math.floor(y / size), fx = x / size - gx, fy = y / size - gy;
  const ease = (t) => t * t * (3 - 2 * t), ex = ease(fx), ey = ease(fy);
  const r = (a, b) => mapRand(7, gx + a, gy + b, n);
  return (r(0, 0) * (1 - ex) + r(1, 0) * ex) * (1 - ey) + (r(0, 1) * (1 - ex) + r(1, 1) * ex) * ey - 0.5;
};
// The lines where a smooth height f(x, y) (x, y in squares across the grid) crosses each of the heights `levels`,
// worked out on a lattice four points to a square: per height, a list of short pieces [x0, y0, x1, y1] in squares.
function mapContours(cols, rows, f, levels) {
  const n = 4, W = cols * n, H = rows * n;
  const v = new Float64Array((W + 1) * (H + 1));
  for (let b = 0; b <= H; b++) for (let a = 0; a <= W; a++) v[b * (W + 1) + a] = f(a / n, b / n);
  return levels.map(L => {
    const out = [];
    for (let b = 0; b < H; b++) for (let a = 0; a < W; a++) {
      const p = [v[b * (W + 1) + a], v[b * (W + 1) + a + 1], v[(b + 1) * (W + 1) + a + 1], v[(b + 1) * (W + 1) + a]];
      const c = [[a, b], [a + 1, b], [a + 1, b + 1], [a, b + 1]];
      const cut = [];
      for (let k = 0; k < 4; k++) {
        const q = (k + 1) % 4;
        if ((p[k] > L) !== (p[q] > L)) { const t = (L - p[k]) / (p[q] - p[k]); cut.push([(c[k][0] + (c[q][0] - c[k][0]) * t) / n, (c[k][1] + (c[q][1] - c[k][1]) * t) / n]); }
      }
      if (cut.length >= 2) out.push([cut[0][0], cut[0][1], cut[1][0], cut[1][1]]);
      if (cut.length === 4) out.push([cut[2][0], cut[2][1], cut[3][0], cut[3][1]]);
    }
    return out;
  });
}
// One grid seen from above (the battle grid). what(i, j) = the ground of a square, also asked past the edge of the
// grid, where the nearest square answers, so a crown rooted just off the grid still hangs over it.
// slope = { ux, uy }: which way is uphill on the mountains and hills of this grid (a unit step east, south); mountain
// squares are then drawn as a mountainside (Peter 2026-10-04: the mountain battle grid should look like a mountain side).
// cliff(i, j) = how steep a square of bare rock is, in degrees, when it is a cliff that has to be climbed (rpg_map_view:
// cells' cliff, step 7c); nothing for any other square.
function mapTop(cols, rows, x0, y0, what, washes, show, hard, slope, cliff) {
  const U = 100;
  const layers = [];
  const bases = new Map();
  const sink = {};
  const add = (k, d) => { sink[k] = (sink[k] || "") + d; };
  const art = (i, j) => MAP_ART.top[what(i, j)] || MAP_ART.top.plain;
  // how hard a square is inside its ground (0 to 9, nothing when not known): harder ground carries more trees, bushes
  // and thorns (from about half as many at 0 to half again as many at 9), and a thicket (9) of a ground with trees is
  // a tangle of thorn bushes
  const hd = (i, j) => (hard ? hard(i, j) : null);
  const dense = (i, j) => { const v = hd(i, j); return v == null ? 1 : 0.55 + v * 0.1; };
  for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++) {
    const tone = art(i, j).tones[Math.floor(mapRand(7, x0 + i, y0 + j, 0) * 3)];
    bases.set(tone, (bases.get(tone) || "") + `M${i * U} ${j * U}h${U}v${U}h${-U}Z`);
  }
  bases.forEach((d, fill) => layers.push({ d, fill }));
  washes.forEach(w => layers.push(w));
  // a mountainside: the ground climbs uphill (slope), with steady bumps from where it lies in the world, and steps up
  // in rock ledges across the slope, one every 1.5 squares (about 1.7 m), a sheer face every third; each ledge has
  // a shadow cast down the slope below its lip and light along the lip's top, and the ledges break off here and
  // there like outcrops. Hills climb the same way in soft lines every 3 squares.
  const steep = (i, j) => { const k = what(Math.min(cols - 1, Math.max(0, i)), Math.min(rows - 1, Math.max(0, j))); return k === "mountains" ? 2 : k === "hills" ? 1 : 0; };
  let climbs = false;
  for (let j = 0; j < rows && !climbs; j++) for (let i = 0; i < cols; i++) if (steep(i, j)) { climbs = true; break; }
  if (slope && climbs) {
    const { ux, uy } = slope;
    const height = (x, y) => { const X = x0 + x, Y = y0 + y; return X * ux + Y * uy + mapWander(X, Y, 3.2, 801) * 2.2 + mapWander(X, Y, 1.1, 802) * 0.7; };
    let lo = Infinity, hi = -Infinity;
    for (let y = 0; y <= rows; y += 0.25) for (let x = 0; x <= cols; x += 0.25) { const h = height(x, y); lo = Math.min(lo, h); hi = Math.max(hi, h); }
    const step = 1.5;
    const first = Math.ceil(lo / step), last = Math.floor(hi / step);
    const levels = [];
    for (let k = first; k <= last; k++) levels.push(k);
    const face = { cliff: "", cliffFar: "", ledge: "", ledgeFar: "", lip: "", lit: "", hill: "" };
    // offset of a piece of line by `by` squares uphill (less than 0 = downhill)
    const shift = (ax, ay, bx, by, k) => mapLine([[(ax + ux * k) * U, (ay + uy * k) * U], [(bx + ux * k) * U, (by + uy * k) * U]]);
    mapContours(cols, rows, height, levels.map(k => k * step)).forEach((list, n) => {
      const k = levels[n], sheer = k % 3 === 0;
      list.forEach(([ax, ay, bx, by]) => {
        const g = steep(Math.floor((ax + bx) / 2), Math.floor((ay + by) / 2));
        if (!g) return;
        if (g === 1) { if (k % 2 === 0) face.hill += mapLine([[ax * U, ay * U], [bx * U, by * U]]); return; }
        // ledges break off here and there, so they read as outcrops of rock; sheer faces run on longer
        if (mapWander(x0 + (ax + bx) / 2, y0 + (ay + by) / 2, 2.4, 803 + k) < (sheer ? -0.32 : -0.12)) return;
        // the shadow the step casts down the slope below its lip, a thin light on the lip's top edge
        if (sheer) { face.cliff += shift(ax, ay, bx, by, -0.1); face.cliffFar += shift(ax, ay, bx, by, -0.2); } else { face.ledge += shift(ax, ay, bx, by, -0.06); face.ledgeFar += shift(ax, ay, bx, by, -0.12); }
        face.lit += shift(ax, ay, bx, by, 0.035);
        face.lip += mapLine([[ax * U, ay * U], [bx * U, by * U]]);
      });
    });
    if (face.hill) layers.push({ d: face.hill, line: "#6F7446", w: 1.1, o: 0.35 });
    // the shadow darkest at the foot of the step, fading down the slope
    if (face.cliffFar) layers.push({ d: face.cliffFar, line: "#2A2620", units: U * 0.4, o: 0.13 });
    if (face.cliff) layers.push({ d: face.cliff, line: "#2A2620", units: U * 0.2, o: 0.24 });
    if (face.ledgeFar) layers.push({ d: face.ledgeFar, line: "#2A2620", units: U * 0.24, o: 0.1 });
    if (face.ledge) layers.push({ d: face.ledge, line: "#2A2620", units: U * 0.12, o: 0.2 });
    if (face.lit) layers.push({ d: face.lit, line: "#EEE9DE", w: 1.2, o: 0.6 });
    if (face.lip) layers.push({ d: face.lip, line: "#4F4A42", w: 1.3, o: 0.8 });
  }
  // cliffs: bare rock too steep to walk, a darker face streaked straight down the slope, the streaks closer the steeper
  // the rock (two at 40 degrees, seven at 85), with light along its top edge and its shadow below
  if (cliff) {
    const ux = slope ? slope.ux : 0, uy = slope ? slope.uy : -1, vx = -uy, vy = ux;
    const rock = { face: "", streak: "", lit: "", foot: "" };
    for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++) {
      const a = cliff(i, j);
      if (a == null) continue;
      const cx = (i + 0.5) * U, cy = (j + 0.5) * U, rnd = (n) => mapRand(7, x0 + i, y0 + j, 700 + n);
      rock.face += `M${i * U} ${j * U}h${U}v${U}h${-U}Z`;
      const n = 2 + Math.round((a - 40) / 9);
      for (let k = 0; k < n; k++) {
        const t = ((k + 0.5) / n - 0.5) * 0.86 * U, l = U * (0.28 + rnd(k) * 0.16), o = (rnd(k + 20) - 0.5) * 0.2 * U;
        const px = cx + vx * t + ux * o, py = cy + vy * t + uy * o;
        rock.streak += mapLine([[px - ux * l, py - uy * l], [px + ux * l, py + uy * l]]);
      }
      // the top edge (uphill side) catches the light; the foot (downhill side) is in shadow
      const edge = (k, w) => mapLine([[cx + ux * k * U - vx * w * U, cy + uy * k * U - vy * w * U], [cx + ux * k * U + vx * w * U, cy + uy * k * U + vy * w * U]]);
      rock.lit += edge(0.44, 0.48);
      rock.foot += edge(-0.44, 0.48);
    }
    if (rock.face) layers.push({ d: rock.face, fill: "#2E2A24", o: 0.3 }, { d: rock.streak, line: "#26221C", w: 1.2, o: 0.6 }, { d: rock.foot, line: "#1E1B16", units: U * 0.1, o: 0.35, cap: "butt" }, { d: rock.lit, line: "#F2EEE4", w: 1.6, o: 0.8 });
  }
  const dry = (i, j) => what(i, j) !== "sea" && !mapWet(what(i, j));
  let wet = false;
  for (let j = 0; j < rows && !wet; j++) for (let i = 0; i < cols; i++) if (!dry(i, j)) { wet = true; break; }
  if (wet) layers.push({ d: mapOutline(cols, rows, dry, U, 0.3), line: "#E6DFC2", units: 9, o: 0.9 });
  // run of the road: along the longer side of what this grid shows of it (a bridge is the road over the water)
  let across = 0, down = 0;
  const onRoad = (i, j) => what(i, j) === "road" || what(i, j) === "bridge";
  for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++) if (onRoad(i, j)) { if (i + 1 < cols && onRoad(i + 1, j)) across += 1; if (j + 1 < rows && onRoad(i, j + 1)) down += 1; }
  const tall = down > across;
  const trees = [];
  for (let j = -4; j < rows + 4; j++) for (let i = -4; i < cols + 4; i++) {
    const a = art(i, j);
    const on = i >= 0 && j >= 0 && i < cols && j < rows;
    const rnd = (n) => mapRand(7, x0 + i, y0 + j, n);
    const at = (n) => [(i + 0.15 + rnd(n) * 0.7) * U, (j + 0.15 + rnd(n + 1) * 0.7) * U];
    if (show ? a.tree && i === 0 && j === 0 : (a.big && rnd(1) < a.big) || (a.tree && rnd(2) < a.tree * dense(i, j))) {
      const big = !show && a.big && rnd(1) < a.big;
      trees.push({ x: (i + 0.3 + rnd(3) * 0.4) * U, y: (j + 0.3 + rnd(4) * 0.4) * U, r: show ? U * 0.4 : U * (big ? 1.5 + rnd(5) * 0.8 : 0.75 + rnd(5) * 0.5), trunk: show ? U * 0.1 : U * (big ? 0.3 + rnd(6) * 0.12 : 0.14 + rnd(6) * 0.08), turn: rnd(7) * 6, gloom: !!a.gloom, needle: !!a.needle, n: 8 + Math.floor(rnd(8) * 4) });
      continue;
    }
    if (!on) continue;
    if (a.wave && rnd(10) < a.wave) { const [x, y] = at(11); const w = U * (0.14 + rnd(13) * 0.1); add("wave", `M${mapPt([x - w, y])}q${mapNum(w / 2)} ${mapNum(-w * 0.5)} ${mapNum(w)} 0t${mapNum(w)} 0`); }
    if (a.blade && rnd(14) < a.blade) for (let n = 0; n < 1 + Math.floor(rnd(15) * 3); n++) { const [x, y] = at(16 + n * 2); const h = U * (0.07 + rnd(22 + n) * 0.06); add("blade", mapLine([[x, y], [x - h * 0.4, y - h]]) + mapLine([[x, y], [x + h * 0.1, y - h * 1.2]]) + mapLine([[x, y], [x + h * 0.5, y - h * 0.8]])); }
    if (a.streak && rnd(26) < a.streak) for (let n = 0; n < 2; n++) { const [x, y] = at(27 + n * 2); const l = U * (0.2 + rnd(31 + n) * 0.3); add("streak", tall ? mapLine([[x, y - l / 2], [x, y + l / 2]]) : mapLine([[x - l / 2, y], [x + l / 2, y]])); }
    // the planks of a bridge (step 11): three boards a square, laid across the road, each with a lit edge
    if (a.plank) for (let n = 0; n < 3; n++) {
      const t = (n + 0.5) / 3 * U + (rnd(160 + n) - 0.5) * U * 0.04;
      add("plank", tall ? mapLine([[i * U, j * U + t], [(i + 1) * U, j * U + t]]) : mapLine([[i * U + t, j * U], [i * U + t, (j + 1) * U]]));
      add("plankLit", tall ? mapLine([[i * U, j * U + t + U * 0.045], [(i + 1) * U, j * U + t + U * 0.045]]) : mapLine([[i * U + t + U * 0.045, j * U], [i * U + t + U * 0.045, (j + 1) * U]]));
    }
    if (a.crack && rnd(33) < a.crack) {
      // on a slope the cracks run straight down it, as gullies do
      const [x, y] = at(34); const l = U * 0.24, cx = slope ? slope.ux : 1, cy = slope ? slope.uy : 0;
      add("crack", mapLine([[-l, -l * rnd(36)], [-l * 0.2, l * 0.2 * (rnd(37) - 0.5)], [l * 0.3, -l * 0.4 * rnd(38)], [l, l * rnd(39)]].map(([p, q]) => [x + p * cx - q * cy, y + p * cy + q * cx])));
    }
    if (a.slab && rnd(40) < a.slab) { const [x, y] = at(41); add("slab", mapStar(x, y, U * (0.16 + rnd(43) * 0.14), 7, 0.82, rnd, rnd(44) * 3)); }
    if (a.puddle && rnd(45) < a.puddle) { const [x, y] = at(46); const w = U * (0.16 + rnd(48) * 0.14); add("puddle", `M${mapPt([x - w, y])}a${mapNum(w)} ${mapNum(w * 0.6)} 0 1 0 ${mapNum(2 * w)} 0a${mapNum(w)} ${mapNum(w * 0.6)} 0 1 0 ${mapNum(-2 * w)} 0Z`); }
    if (a.root && rnd(49) < a.root) { const [x, y] = at(50); const l = U * (0.3 + rnd(52) * 0.3), t = rnd(53) * 6.3; add("root", `M${mapPt([x - Math.cos(t) * l, y - Math.sin(t) * l])}Q${mapPt([x + Math.sin(t) * l * 0.5, y - Math.cos(t) * l * 0.5])} ${mapPt([x + Math.cos(t) * l, y + Math.sin(t) * l])}`); }
    if (a.pebble && rnd(54) < a.pebble) for (let n = 0; n < 1 + Math.floor(rnd(55) * 3); n++) { const [x, y] = at(56 + n * 2); add("pebble", mapCircle(x, y, U * (0.025 + rnd(62 + n) * 0.03))); }
    if (a.flower && rnd(65) < a.flower) for (let n = 0; n < 1 + Math.floor(rnd(66) * 3); n++) { const [x, y] = at(67 + n * 2); add(rnd(73 + n) < 0.5 ? "petal" : "gold", mapCircle(x, y, U * 0.035)); }
    if (a.cobble && rnd(76) < a.cobble) for (let n = 0; n < 3 + Math.floor(rnd(77) * 3); n++) { const [x, y] = at(78 + n * 2); add("cobble", mapStar(x, y, U * (0.06 + rnd(88 + n) * 0.04), 6, 0.9, (q) => rnd(q + n * 7), rnd(94 + n) * 3)); }
    if (a.rock && rnd(100) < a.rock) { const [x, y] = at(101); const r = U * (0.2 + rnd(103) * 0.22), t = rnd(104) * 3; add("shade", mapStar(x + r * 0.16, y + r * 0.2, r, 7, 0.86, rnd, t)); add("rock", mapStar(x, y, r, 7, 0.86, rnd, t)); add("rockLit", mapStar(x - r * 0.18, y - r * 0.2, r * 0.5, 7, 0.86, rnd, t)); }
    if (a.block && rnd(105) < a.block) for (let n = 0; n < 1 + Math.floor(rnd(106) * 2); n++) {
      const [x, y] = at(107 + n * 2); const w = U * (0.16 + rnd(111 + n) * 0.14), h = U * (0.1 + rnd(113 + n) * 0.08), t = rnd(115 + n) * 3.2, c = Math.cos(t), s = Math.sin(t);
      const box = (ox, oy) => mapPoly([[-w, -h], [w, -h], [w, h * 0.3], [w * 0.6, h], [-w, h]].map(([px, py]) => [x + ox + px * c - py * s, y + oy + px * s + py * c]));
      add("shade", box(U * 0.03, U * 0.04)); add("block", box(0, 0));
    }
    if (a.bush && rnd(117) < a.bush * dense(i, j)) { const [x, y] = at(118); const r = U * (0.2 + rnd(120) * 0.16), t = rnd(121) * 6; add("shade", mapBlob(x + r * 0.14, y + r * 0.18, r, 7, t)); add("bush", mapBlob(x, y, r, 7, t)); add("bushLit", mapBlob(x - r * 0.16, y - r * 0.18, r * 0.5, 6, t)); }
    if ((a.thorn && rnd(122) < a.thorn * dense(i, j)) || (a.tree && hd(i, j) === 9 && rnd(122) < 0.85)) { const [x, y] = at(123); const r = U * (0.18 + rnd(125) * 0.16), t = rnd(126) * 3; add("shade", mapCircle(x + r * 0.12, y + r * 0.16, r * 0.8)); add("thorn", mapStar(x, y, r, 14, 0.5, rnd, t)); add("thornLit", mapStar(x - r * 0.1, y - r * 0.1, r * 0.5, 10, 0.5, rnd, t)); }
    if (a.mist && rnd(127) < a.mist) { const [x, y] = at(128); const w = U * (0.2 + rnd(130) * 0.15); add("mist", `M${mapPt([x - w, y])}q${mapNum(w / 2)} ${mapNum(-w * 0.45)} ${mapNum(w)} 0t${mapNum(w)} 0`); }
    if (a.ripple && rnd(131) < a.ripple) for (let n = 0; n < 2; n++) { const [x, y] = at(132 + n * 2); const w = U * (0.16 + rnd(136 + n) * 0.12); add("ripple", `M${mapPt([x - w, y])}q${mapNum(w / 2)} ${mapNum(-w * 0.3)} ${mapNum(w)} 0t${mapNum(w)} 0`); }
    if (a.frost && rnd(138) < a.frost) { const [x, y] = at(139); const l = U * (0.14 + rnd(141) * 0.12); add("frost", mapLine([[x - l, y], [x - l * 0.3, y - l * 0.35], [x + l * 0.2, y + l * 0.1], [x + l, y - l * 0.2]])); }
    if (a.reed && rnd(142) < a.reed) for (let n = 0; n < 1 + Math.floor(rnd(143) * 3); n++) { const [x, y] = at(144 + n * 2); const h = U * (0.12 + rnd(150 + n) * 0.1); add("reed", mapLine([[x, y], [x - h * 0.2, y - h]]) + mapLine([[x, y], [x + h * 0.05, y - h * 1.15]]) + mapLine([[x, y], [x + h * 0.3, y - h * 0.85]])); }
    if (a.drift && rnd(153) < a.drift) { const [x, y] = at(154); const w = U * (0.12 + rnd(156) * 0.14); add("drift", `M${mapPt([x - w, y])}a${mapNum(w)} ${mapNum(w * 0.55)} 0 1 0 ${mapNum(2 * w)} 0a${mapNum(w)} ${mapNum(w * 0.55)} 0 1 0 ${mapNum(-2 * w)} 0Z`); }
  }
  // trees last: every shadow, then every trunk, then the crowns, smallest first, so the trunk shows through its crown
  trees.sort((a, b) => a.r - b.r);
  // a broadleaf crown is a bumpy round; a pine's is a star of short points
  const crown = (t, x, y, r, n, turn) => (t.needle ? mapStar(x, y, r, n * 2, 0.66, () => 0.6, turn) : mapBlob(x, y, r, n, turn));
  trees.forEach(t => add("shade", crown(t, t.x + t.r * 0.1, t.y + t.r * 0.13, t.r, t.n, t.turn)));
  trees.forEach(t => add("trunk", mapCircle(t.x, t.y, t.trunk)));
  MAP_ART.paint.forEach(s => { if (sink[s.k]) layers.push({ ...s, d: sink[s.k] }); });
  trees.forEach(t => {
    const set = t.gloom ? ["gloomDark", "gloom", "gloomLit"] : t.needle ? ["needleDark", "needle", "needleLit"] : ["leafDark", "leaf", "leafLit"];
    const style = (k) => MAP_ART.paint.find(s => s.k === k);
    layers.push({ ...style(set[0]), d: crown(t, t.x, t.y, t.r, t.n, t.turn) }, { ...style(set[1]), d: crown(t, t.x - t.r * 0.04, t.y - t.r * 0.05, t.r * 0.86, t.n, t.turn + 0.3) }, { ...style(set[2]), d: crown(t, t.x - t.r * 0.2, t.y - t.r * 0.24, t.r * 0.46, 6, t.turn) });
  });
  return layers;
}
// The houses of a village, town or city seen from above (rpg_map_view: houses; step 8c), each a roof over its walls:
// x, y = its middle and len, wide = its length and width, all in thousandths of a square from the grid's top-left
// corner; ridge = the way its ridge runs. Thatch (a village) is hipped, its straw combed down the slopes; clay tiles (a
// town or city) are gabled, laid in courses along the ridge. The sun is in the north-west, as for the trees: the slopes
// that face it are lit, the house casts its shadow south-east, longer the higher its eaves (eaves, in metres). unit =
// drawing units a square.
const MAP_ROOFS = {
  thatch: { lit: "#D9B972", dark: "#8C6C36", grain: "#6E5329", ridge: "#5F4622", edge: "#3E2E18" },
  tile: { lit: "#C46C4B", dark: "#7C3826", grain: "#5E2A1B", ridge: "#4C2014", edge: "#36180F" },
};
function mapRoofs(houses, unit) {
  const sink = {};
  const add = (k, d) => { sink[k] = (sink[k] || "") + d; };
  const sun = [-0.55, -0.83];
  (Array.isArray(houses) ? houses : []).forEach((h, n) => {
    const style = MAP_ROOFS[h.roof] ? h.roof : "tile";
    const r = Array.isArray(h.ridge) ? h.ridge : [1000, 0];
    const rl = Math.hypot(r[0], r[1]) || 1;
    const ux = r[0] / rl, uy = r[1] / rl, vx = -uy, vy = ux;
    const X = (Number(h.x) || 0) * unit / 1000, Y = (Number(h.y) || 0) * unit / 1000;
    const hl = (Number(h.len) || 0) * unit / 2000, hw = (Number(h.wide) || 0) * unit / 2000;
    if (!(hl > 0 && hw > 0)) return;
    const pt = (a, b) => [X + a * ux + b * vx, Y + a * uy + b * vy];
    const foot = [pt(-hl, -hw), pt(hl, -hw), pt(hl, hw), pt(-hl, hw)];
    // the shadow, cast south-east: a twentieth of a square for every metre to the eaves
    const k = unit * 0.05 * (Number(h.eaves) || 2.5);
    add("shadow", mapPoly(foot.map(([x, y]) => [x + k * 0.55, y + k * 0.83])));
    // the slopes: each lit by how squarely it faces the sun
    const hip = style === "thatch" ? Math.max(hl - hw, 0) : hl;
    const faces = style === "thatch"
      ? [[[pt(-hip, 0), pt(hip, 0), pt(hl, hw), pt(-hl, hw)], [vx, vy]], [[pt(-hip, 0), pt(hip, 0), pt(hl, -hw), pt(-hl, -hw)], [-vx, -vy]],
         [[pt(hip, 0), pt(hl, hw), pt(hl, -hw)], [ux, uy]], [[pt(-hip, 0), pt(-hl, hw), pt(-hl, -hw)], [-ux, -uy]]]
      : [[[pt(-hl, 0), pt(hl, 0), pt(hl, hw), pt(-hl, hw)], [vx, vy]], [[pt(-hl, 0), pt(hl, 0), pt(hl, -hw), pt(-hl, -hw)], [-vx, -vy]]];
    // the two long slopes always differ, so a roof whose ridge runs toward the sun still reads as a roof: the one that
    // faces more west is the lit one
    faces.forEach(([poly, [nx, ny]], f) => {
      let d = nx * sun[0] + ny * sun[1];
      if (f < 2 && Math.abs(d) < 0.5) d = (Math.abs(d) > 1e-6 ? Math.sign(d) : nx <= 0 ? 1 : -1) * 0.5;
      add(`${style}:${Math.round((d + 1) * 2)}`, mapPoly(poly));
    });
    // the grain: straw down each long slope, or courses of tiles along it with their joints
    const rnd = (q) => mapRand(12, Math.round(X), Math.round(Y), q + n);
    if (style === "thatch") {
      const step = unit * 0.14;
      for (const side of [1, -1]) for (let a = -hip + step / 2; a < hip; a += step) {
        const j = (rnd(Math.round(a)) - 0.5) * step * 0.6;
        add(`${style}:grain`, mapLine([pt(a + j, side * hw * 0.12), pt(a + j, side * hw * 0.94)]));
      }
    } else {
      const step = unit * 0.22, joint = unit * 0.3;
      for (const side of [1, -1]) for (let b = step; b < hw; b += step) {
        add(`${style}:grain`, mapLine([pt(-hl, side * b), pt(hl, side * b)]));
        const shift = (Math.round(b / step) % 2) * joint / 2;
        for (let a = -hl + joint / 2 + shift; a < hl; a += joint) add(`${style}:grain`, mapLine([pt(a, side * b), pt(a, side * Math.max(b - step, 0))]));
      }
    }
    // the ridge and, on a hipped roof, the hips down to the corners; the eaves round the edge
    add(`${style}:ridge`, mapLine([pt(-hip, 0), pt(hip, 0)]));
    if (style === "thatch") [[1, 1], [1, -1], [-1, 1], [-1, -1]].forEach(([a, b]) => add(`${style}:ridge`, mapLine([pt(a * hip, 0), pt(a * hl, b * hw)])));
    add(`${style}:edge`, mapPoly(foot));
  });
  const out = [];
  if (sink.shadow) out.push({ d: sink.shadow, fill: "#000000", o: 0.22 });
  Object.keys(MAP_ROOFS).forEach(s => {
    const c = MAP_ROOFS[s];
    for (let t = 0; t <= 4; t++) if (sink[`${s}:${t}`]) out.push({ d: sink[`${s}:${t}`], fill: mapMix(c.dark, c.lit, t / 4) });
    if (sink[`${s}:grain`]) out.push({ d: sink[`${s}:grain`], line: c.grain, w: 0.7, o: 0.45 });
    if (sink[`${s}:ridge`]) out.push({ d: sink[`${s}:ridge`], line: c.ridge, w: 1.8, o: 0.9 });
    if (sink[`${s}:edge`]) out.push({ d: sink[`${s}:edge`], line: c.edge, w: 1.1, o: 0.85 });
  });
  return out;
}
// The battle grid: every square seen from above, with a light wash of each place's color and the lines of the grid.
function mapBattle(v, byId) {
  const cols = Number(v.cols) || 12, rows = Number(v.rows) || 12;
  const cells = Array.isArray(v.cells) ? v.cells : [];
  // where the battle grid starts in the world (step 14a2: it may be slid half a grid)
  const o0 = mapOrigin(v);
  const grid = new Array(cols * rows).fill(null);
  // a square carried over water by a bridge, or in a ford, draws as that (step 11; rpg_map_view: cells' cross)
  cells.forEach(c => { const p = c.place && !mapWet(c.kind) ? byId[c.place] : null; grid[(c.y - 1) * cols + (c.x - 1)] = { what: c.cross === "bridge" || c.cross === "ford" ? c.cross : p ? (MAP_ART.top[p.icon] ? p.icon : "plain") : c.kind, id: c.place || null, h: c.hard == null ? null : Number(c.hard), cliff: c.cliff == null ? null : Number(c.cliff) }; });
  const get = (i, j) => grid[(j < 0 ? 0 : j >= rows ? rows - 1 : j) * cols + (i < 0 ? 0 : i >= cols ? cols - 1 : i)] || { what: "plain" };
  const washes = [];
  Array.from(new Set(grid.filter(g => g && g.id).map(g => g.id))).forEach(id => { const p = byId[id]; if (p && p.color) washes.push({ d: mapOutline(cols, rows, (i, j) => get(i, j).id === id, 100, 0.3), fill: p.color, o: 0.14 }); });
  const inGrid = (i, j) => i >= 0 && j >= 0 && i < cols && j < rows;
  washes.push(...mapHardShade(cols, rows, (i, j) => (!inGrid(i, j) || mapWet(get(i, j).what) ? null : get(i, j).h), 100, 0.3));
  washes.push(...mapHardShade(cols, rows, (i, j) => (inGrid(i, j) && mapWet(get(i, j).what) ? get(i, j).h : null), 100, 0.3, "#123A5A"));
  const lines = [];
  for (let i = 1; i < cols; i++) lines.push(mapLine([[i * 100, 0], [i * 100, rows * 100]]));
  for (let j = 1; j < rows; j++) lines.push(mapLine([[0, j * 100], [cols * 100, j * 100]]));
  // which way is uphill: the cells' rise (rpg_map_view: how near each mountain or hill square is to the middle line
  // of its chain) fitted to a flat slope; with too little to go on, a steady way of its own
  const ups = cells.filter(c => c.rise != null).map(c => [c.x, c.y, Number(c.rise)]);
  let slope = null;
  if (ups.length >= 3) {
    const mx = ups.reduce((t, u) => t + u[0], 0) / ups.length, my = ups.reduce((t, u) => t + u[1], 0) / ups.length, mr = ups.reduce((t, u) => t + u[2], 0) / ups.length;
    let xx = 0, xy = 0, yy = 0, xr = 0, yr = 0;
    ups.forEach(([x, y, r]) => { xx += (x - mx) ** 2; xy += (x - mx) * (y - my); yy += (y - my) ** 2; xr += (x - mx) * (r - mr); yr += (y - my) * (r - mr); });
    const det = xx * yy - xy * xy;
    const gx = det ? (xr * yy - yr * xy) / det : 0, gy = det ? (yr * xx - xr * xy) / det : 0, len = Math.hypot(gx, gy);
    if (len > 0) slope = { ux: gx / len, uy: gy / len };
  }
  if (!slope && cells.some(c => c.kind === "mountains" || c.kind === "hills")) { const t = mapRand(7, Math.floor(o0[0] / cols), Math.floor(o0[1] / rows), 800) * 2 * Math.PI; slope = { ux: Math.cos(t), uy: Math.sin(t) }; }
  const layers = mapTop(cols, rows, o0[0], o0[1], (i, j) => get(i, j).what, washes, false, (i, j) => get(i, j).h, slope, (i, j) => (inGrid(i, j) ? get(i, j).cliff : null));
  // the houses stand on the ground (step 8c)
  layers.push(...mapRoofs(v.houses, 100));
  // and the landmarks (step 12b2)
  layers.push(...mapBuilt(cols, rows, cells));
  const fog = mapFog(cols, rows, 100, (i, j) => get(i, j).what === "unknown", 0.3, cols, rows, 7, o0[0], o0[1]);
  return { wide: cols * 100, high: rows * 100, unit: 100, layers: layers.concat([{ d: lines.join(""), line: "#2B2418", w: 1, o: 0.3 }], fog), names: [], blocks: [] };
}
// The squares landmarks stand on (step 12b2), over the ground and the houses: each kind as one outline of its squares,
// a castle wall, a keep or a ruin with the courses of its stones, a cairn with its stones.
function mapBuilt(cols, rows, cells) {
  const at = new Map();
  cells.forEach(c => { if (Array.isArray(c.climb) && MAP_BUILT[c.climb[0]]) at.set((c.y - 1) * cols + (c.x - 1), c.climb[0]); });
  const out = [];
  // the floors and mouths (step 12c)
  const ft = new Map();
  cells.forEach(c => { if (c.feature && MAP_FEATURE[c.feature]) ft.set((c.y - 1) * cols + (c.x - 1), c.feature === "mouth" ? "mouth" : "floor"); });
  ["floor", "mouth"].forEach(kind => {
    const look = MAP_FEATURE[kind];
    const d = mapOutline(cols, rows, (i, j) => i >= 0 && j >= 0 && i < cols && j < rows && ft.get(j * cols + i) === kind, 100, look.round || 0.05);
    if (d) out.push({ d, fill: look.fill, line: look.line, w: look.w });
  });
  let boards = "";
  cells.forEach(c => {
    const look = MAP_FEATURE[c.feature];
    if (!look || c.feature === "mouth") return;
    const x = (c.x - 1) * 100, y = (c.y - 1) * 100;
    boards += `M${x} ${y + 33}H${x + 100}M${x} ${y + 67}H${x + 100}`;
    if (look.mark && look.mark.r) out.push({ d: mapCircle(x + 50, y + 50, look.mark.r), fill: look.mark.fill, line: look.mark.line, w: 1 });
    if (look.mark && look.mark.box) out.push({ d: mapPoly([[x + 50 - look.mark.box, y + 50 - look.mark.box * 0.6], [x + 50 + look.mark.box, y + 50 - look.mark.box * 0.6], [x + 50 + look.mark.box, y + 50 + look.mark.box * 0.6], [x + 50 - look.mark.box, y + 50 + look.mark.box * 0.6]]), fill: look.mark.fill, line: look.mark.line, w: 1.2 });
  });
  if (boards) out.push({ d: boards, line: MAP_FEATURE.floor.line, w: 0.6, o: 0.5 });
  Object.entries(MAP_BUILT).forEach(([part, look]) => {
    const mine = Array.from(at.entries()).filter(([, p]) => p === part).map(([n]) => n);
    if (!mine.length) return;
    const d = mapOutline(cols, rows, (i, j) => i >= 0 && j >= 0 && i < cols && j < rows && at.get(j * cols + i) === part, 100, look.round);
    if (d) out.push({ d, fill: look.fill, line: look.line, w: look.w, o: look.o });
    let marks = "";
    mine.forEach(n => {
      const x = (n % cols) * 100, y = Math.floor(n / cols) * 100;
      if (look.joints) marks += `M${x + 8} ${y + 34}H${x + 92}M${x + 8} ${y + 67}H${x + 92}M${x + 50} ${y + 8}V${y + 34}M${x + 28} ${y + 34}V${y + 67}M${x + 72} ${y + 34}V${y + 67}M${x + 50} ${y + 67}V${y + 92}`;
      if (look.pile) [[35, 38, 16], [64, 40, 14], [48, 64, 17]].forEach(([u, v, r]) => { marks += mapCircle(x + u, y + v, r); });
    });
    if (marks) out.push({ d: marks, line: look.line, w: 0.8, o: 0.55 });
  });
  return out;
}
// The strokes as SVG. A stroke's line is w screen pixels wide (thinner on a small map), or `units` of the drawing
// wide less `inset` screen pixels (the fill of a road inside its inked edge) but never under `min` screen pixels (a
// road drawn true to its width when the map is close, as a line when it is far out). A stroke with a clip (the outline
// of a shape) paints only inside that shape: the soft edge of a ground stays on the land and off the sea.
let mapClips = 0;
function MapStrokes({ layers, px, unit }) {
  const id = useRef("rpg-map-clip-" + (++mapClips)).current;
  const pen = Math.max(0.4, Math.min(1, px * unit * 0.06));
  const clips = [];
  layers.forEach(l => { if (l.clip && !clips.includes(l.clip)) clips.push(l.clip); });
  return (
    <>
      {clips.length > 0 && <defs>{clips.map((d, n) => <clipPath key={n} id={id + "-" + n}><path d={d} /></clipPath>)}</defs>}
      {layers.map((l, n) => (
        <path key={n} d={l.d} fill={l.fill || "none"} stroke={l.line || "none"} opacity={l.o}
          strokeWidth={l.line ? (l.units != null ? Math.max(l.min ? l.min * pen / px : 0, l.units - (l.inset || 0) / px) : l.w * pen / px) : undefined}
          clipPath={l.clip ? `url(#${id}-${clips.indexOf(l.clip)})` : undefined}
          strokeLinejoin="round" strokeLinecap={l.cap || "round"} strokeDasharray={l.dash ? l.dash.map(n2 => n2 * pen / px).join(" ") : undefined} />
      ))}
    </>
  );
}
// Where the names go. Each tries a few spots round its place and takes the first that is clear of the names already
// written and of the symbols (blocks); a small place whose name fits nowhere goes without (it is still in the lists
// and on its cell). A name's size is in screen pixels, but the N over the compass rose is sized in units of the drawing.
function mapNames(names, blocks, px, wide, high) {
  const done = blocks.map(b => [0, 0, b[0], b[1], b[2], b[3]]);
  const out = [];
  names.forEach((n) => {
    if (n.count) { out.push({ ...n, cx: n.x, cy: n.y, size: 12 / px }); return; }
    if (n.north) { out.push({ ...n, cx: n.x, cy: n.y, caps: true }); done.push([0, 0, n.x - n.size * 3.2, n.y - n.size, n.x + n.size * 3.2, n.y + n.size * 7]); return; }
    const len = n.text.length;
    const small = Math.max(0.78, Math.min(1, Math.sqrt(px / 0.5)));
    const sizePx = n.caps ? Math.max(8.5, Math.min(26, (n.room * px * 0.9) / (len * 0.95))) : n.size * small;
    const size = sizePx / px, w = len * size * (n.caps ? 0.95 : 0.5), r = n.r || 0;
    const tries = n.caps || n.mid ? [0, -1.4, 1.4, -2.8, 2.8].map(k => [n.x, n.y + k * size])
      : n.way ? [0, n.way, -n.way].flatMap(dx => [[n.x + dx, n.y + r + size * 0.8], [n.x + dx, n.y - r - size * 0.65]])
        : [[n.x, n.y + r + size * 0.75], [n.x, n.y - r - size * 0.6], [n.x + r + size * 0.4 + w / 2, n.y], [n.x - r - size * 0.4 - w / 2, n.y], [n.x, n.y + r + size * 2], [n.x, n.y - r - size * 1.9]];
    const boxes = tries.map(([x, y]) => { const cx = Math.max(w / 2 + 4, Math.min(wide - w / 2 - 4, x)); return [cx, y, cx - w / 2 - 2, y - size * 0.62, cx + w / 2 + 2, y + size * 0.5]; })
      .filter(b => b[3] >= 0 && b[5] <= high);
    const free = boxes.find(b => !done.some(q => b[2] < q[4] && b[4] > q[2] && b[3] < q[5] && b[5] > q[3]));
    const b = free || (n.must ? boxes[0] : null);
    if (!b) return;
    done.push(b);
    out.push({ ...n, cx: b[0], cy: b[1], size });
  });
  return out;
}
// The picture under the cells of the grid: the strokes, an aged edge and a neat line on the fantasy map, the names.
// The world under the ground (step 12d; rpg_map_view: under), drawn in place of the land when the Underground switch is
// on (step 14a, Peter 2026-10-07: a switch that takes the land away, and tunnels and caves rather than coloured lines):
// solid rock, flecked; each passage a tunnel cut into it, a dark wall either side of a pale floor. Where the passage is
// wide enough on the map for its bends to show, the server sends its path (line 9: rpg_map_under_trace, the passage
// the battle grid cuts into squares) and the tunnel is drawn along it, as wide as it runs at each point (step 14a2,
// Peter 2026-10-07: the battle grid did not match the grid above it); elsewhere it is drawn along its curve at its
// middle width (line 8), never thinner than its kind's least width on the screen. Nothing of the page's own bends: the
// shape is the server's. The room at each node it reaches is a cave of the same rock-and-floor, its ragged edge through
// the eight knots the battle grid uses (rooms); a shaft a dark round hole; the great halls of the Deeps named from the
// Country grid down; the coast above a faint line. The Continent and Country grids carry the Deeps alone (step 14a2),
// drawn fine there so the network reads as threads through the rock. The colours are the one home for the Maps tab
// and its key.
const MAP_UNDER = {
  deep: { floor: "#8F8798", min: 7, words: "The Deeps: 13,000 to 26,000 feet below the sea, a great hall about every 86 miles; most halls join one network round the world, under the seas too." },
  cave: { floor: "#A6957B", min: 5, words: "Cave country: chambers 100 to 9,800 feet down, about one every 2.4 miles where the rock holds caves (3 in 10 of the land)." },
  own: { floor: "#BCA98B", min: 5.5, words: "A cave or mine's own passage, from its mouth into the hill: a great cave up to 3 miles long, mine workings down a shaft up to 13,000 feet." },
  join: { floor: "#A6957B", min: 2.4, words: "A narrow squeeze: where a cave or mine breaks into cave country or down into the Deeps." },
  delve: { floor: "#8F8798", min: 2.4 },
  shaft: { floor: "#8F8798", min: 0 },
};
const MAP_UNDER_ROCK = "#2B2420";
const MAP_UNDER_WALL = "#120D0A";
// A closed outline in whole units, always turning the same way round (by its signed area), so many of them laid in
// one shape fill as one where they overlap instead of cutting holes in each other.
function mapUnderShape(pts) {
  let a = 0;
  for (let k = 0; k < pts.length; k++) { const p = pts[k], q = pts[(k + 1) % pts.length]; a += p[0] * q[1] - q[0] * p[1]; }
  const run = a < 0 ? pts.slice().reverse() : pts;
  return "M" + run.map(p => `${Math.round(p[0])} ${Math.round(p[1])}`).join("L") + "Z";
}
// Flecks of lighter and darker stone over the rock, about one every 26 screen pixels, steady for each spot of the world.
function mapUnderFlecks(wide, high, px, lvl, x0, y0) {
  const step = 26 / px, out = [];
  for (let y = 0; y < high; y += step) for (let x = 0; x < wide; x += step) {
    const gx = Math.floor((x0 * 100 + x) / step), gy = Math.floor((y0 * 100 + y) / step);
    const a = mapRand(lvl, gx, gy, 701), b = mapRand(lvl, gx, gy, 702), c = mapRand(lvl, gx, gy, 703);
    out.push({ x: x + a * step, y: y + b * step, r: (0.8 + 1.8 * c) / px, light: c > 0.55 });
  }
  return out;
}
// A room's edge (rpg_map_under_room): points round its middle, from the west going north as the knots run, each
// 0.75 + 0.5 x the knot of r out, smooth between knots (the battle grid's sum).
function mapUnderRoom(x, y, r, knots, px) {
  const k = Array.isArray(knots) && knots.length === 8 ? knots.map(n => Number(n) / 1000) : new Array(8).fill(0.5);
  const pts = [];
  // 32 points round a cave more than 15 screen pixels across the middle, 16 round a smaller one
  const each = r * px > 15 ? 4 : 2;
  for (let s = 0; s < 8 * each; s++) {
    const f = s / each, i = Math.floor(f), t = f - i, sm = t * t * (3 - 2 * t);
    const q = k[i % 8] + (k[(i + 1) % 8] - k[i % 8]) * sm;
    const a = -Math.PI + f * Math.PI / 4;
    pts.push([x + Math.cos(a) * r * (0.75 + 0.5 * q), y + Math.sin(a) * r * (0.75 + 0.5 * q)]);
  }
  return mapUnderShape(pts);
}
// Where a grid or a block starts in the world, in its own cells: v.origin (the first cell of the block), else the grid
// named by the view (level-x-y).
function mapOrigin(v) {
  if (Array.isArray(v.origin) && v.origin.length === 2) return [Number(v.origin[0]) || 0, Number(v.origin[1]) || 0];
  const cols = Number(v.cols) || 12, rows = Number(v.rows) || 12, m = /^(\d+)-(\d+)-(\d+)$/.exec(v.view || "");
  return m ? [Number(m[2]) * cols, Number(m[3]) * rows] : [0, 0];
}
// A tunnel as a shape along points of its middle, each [x, y, half its width] in units (step 14a2): the two walls walked
// out and back as one closed outline, each point moved to either side across the line through its neighbours; a round
// end where the tunnel ends on the map (end: [at its first point, at its last]).
function mapUnderPath(pts, end) {
  if (!Array.isArray(pts) || pts.length < 2) return "";
  const left = [], right = [], n = pts.length;
  for (let s = 0; s < n; s++) {
    const a = pts[Math.max(s - 1, 0)], b = pts[Math.min(s + 1, n - 1)];
    const dx = b[0] - a[0], dy = b[1] - a[1], len = Math.hypot(dx, dy) || 1, nx = -dy / len, ny = dx / len, h = pts[s][2];
    left.push([pts[s][0] + nx * h, pts[s][1] + ny * h]);
    right.push([pts[s][0] - nx * h, pts[s][1] - ny * h]);
  }
  const cap = (p, q, h) => {
    // a half round past p, away from q
    const dx = p[0] - q[0], dy = p[1] - q[1], len = Math.hypot(dx, dy) || 1, ux = dx / len, uy = dy / len, out = [];
    for (let k = 1; k < 6; k++) { const a = Math.PI * k / 6; out.push([p[0] + (-uy * Math.cos(a) + ux * Math.sin(a)) * h, p[1] + (ux * Math.cos(a) + uy * Math.sin(a)) * h]); }
    return out;
  };
  // the end caps: past the last point from the left wall round to the right, past the first from the right round to the left
  const tail = end && end[1] ? cap(pts[n - 1], pts[n - 2], pts[n - 1][2]) : [];
  const head = end && end[0] ? cap(pts[0], pts[1], pts[0][2]) : [];
  return mapUnderShape(left.concat(tail, right.reverse(), head));
}
function MapUnder({ v, px }) {
  const cols = Number(v.cols) || 12, rows = Number(v.rows) || 12, wide = cols * 100, high = rows * 100;
  const under = v.under && typeof v.under === "object" ? v.under : {};
  const lines = Array.isArray(under.lines) ? under.lines : [];
  const halls = Array.isArray(under.halls) ? under.halls : [];
  const rooms = Array.isArray(under.rooms) ? under.rooms : [];
  const cells = Array.isArray(v.cells) ? v.cells : [];
  const lvl = Number(v.level) || 1;
  const [x0, y0] = mapOrigin(v);
  // the Continent and Country grids carry the Deeps alone, drawn fine (step 14a2): a passage at least 1 screen pixel
  // wide on the Continent grid and 2 on the Country grid, a great hall 3 and 6 across; finer grids by each kind's least
  const fine = lvl <= 2 ? { line: 1, hall: 3, wall: 0.8 } : lvl === 3 ? { line: 2, hall: 6, wall: 1.2 } : null;
  const drawn = useMemo(() => {
    const flecks = mapUnderFlecks(wide, high, px, lvl, x0, y0);
    // the coast above: land cells (not sea, not unknown) outlined
    const kind = (i, j) => { const c = i >= 0 && j >= 0 && i < cols && j < rows ? cells[j * cols + i] : null; return c ? c.kind : null; };
    const coast = cells.some(c => c.kind === "sea") ? mapOutline(cols, rows, (i, j) => { const k = kind(i, j); return k != null && k !== "sea" && k !== "unknown"; }, 100, 0.45, { lvl, x0, y0 }) : "";
    const tunnels = lines.map((l, n) => {
      const [kind, ax, ay, bx, by, , , bend, width] = l;
      const look = MAP_UNDER[kind] || MAP_UNDER.cave;
      const p0 = [ax / 10, ay / 10], p1 = [bx / 10, by / 10], dx = p1[0] - p0[0], dy = p1[1] - p0[1];
      const least = (fine ? fine.line : look.min) / px;
      const w = Math.max((Number(width) || 0) / 10, least);
      if (kind === "shaft") return { n, kind, look, hole: p0, w: Math.max(w, 5 / px) };
      // the passage as the battle grid cuts it, where the server sends it (rpg_map_under_trace)
      if (Array.isArray(l[9]) && l[9].length > 1) {
        const pts = l[9].map(q => [Number(q[0]) / 10, Number(q[1]) / 10, Math.max(Number(q[2]) / 10, least / 2)]);
        return { n, kind, look, w, d: mapUnderPath(pts, [true, true]) };
      }
      // else its curve (rpg_map_under_curve: the middle pulled to one side by bend x a quarter of its length) at its
      // middle width, only the stretch near the map, a point every 9 screen pixels
      const k = (Number(bend) || 0) / 100 * 0.25, c = [(p0[0] + p1[0]) / 2 - dy * k, (p0[1] + p1[1]) / 2 + dx * k];
      const at = (t) => [(1 - t) * (1 - t) * p0[0] + 2 * t * (1 - t) * c[0] + t * t * p1[0], (1 - t) * (1 - t) * p0[1] + 2 * t * (1 - t) * c[1] + t * t * p1[1]];
      const pad = 2 * w + 20 / px, near = (q) => q[0] > -pad && q[1] > -pad && q[0] < wide + pad && q[1] < high + pad;
      let t0 = 1, t1 = 0;
      for (let s = 0; s <= 200; s++) { const t = s / 200; if (near(at(t))) { t0 = Math.min(t0, t); t1 = Math.max(t1, t); } }
      if (t1 < t0) return { n, kind, look, w, d: "" };
      t0 = Math.max(0, t0 - 1 / 200); t1 = Math.min(1, t1 + 1 / 200);
      const L = Math.hypot(c[0] - p0[0], c[1] - p0[1]) + Math.hypot(p1[0] - c[0], p1[1] - c[1]);
      const cnt = Math.min(Math.max(Math.ceil((t1 - t0) * L * px / 9), 2), 200), pts = [];
      for (let s = 0; s <= cnt; s++) { const q = at(t0 + (t1 - t0) * s / cnt); pts.push([q[0], q[1], w / 2]); }
      return { n, kind, look, w, d: mapUnderPath(pts, [true, true]) };
    });
    // a great hall (where the Deeps meet) never smaller than 10 screen pixels across the middle, any other cave 4
    // (the Continent and Country grids: as fine says)
    const hallAt = new Set(halls.map(h => `${h[1]},${h[2]}`));
    const caves = rooms.map((r, n) => {
      const rr = Math.max((Number(r[2]) || 0) / 10, (fine ? fine.hall : hallAt.has(`${r[0]},${r[1]}`) ? 10 : 4) / 2 / px);
      return { n, d: mapUnderRoom(r[0] / 10, r[1] / 10, rr, r[3], px) };
    });
    // every wall in one shape and the floors of each colour in one shape each, so the drawing stays light
    const walls = caves.map(c => c.d).concat(tunnels.filter(t => !t.hole).map(t => t.d)).join("");
    const floors = {};
    caves.forEach(c => { floors[MAP_UNDER.cave.floor] = (floors[MAP_UNDER.cave.floor] || "") + c.d; });
    tunnels.filter(t => !t.hole).forEach(t => { floors[t.look.floor] = (floors[t.look.floor] || "") + t.d; });
    return { flecks, coast, tunnels, walls, floors };
  }, [v, px]);
  const wall = (fine ? fine.wall : 2.4) / px;
  return (
    <svg viewBox={`0 0 ${wide} ${high}`} preserveAspectRatio="none" aria-hidden="true"
      style={{ position: "absolute", left: 16, top: 16, width: "calc(100% - 16px)", height: "calc(100% - 16px)", borderRadius: 4, pointerEvents: "none", display: "block", overflow: "hidden" }}>
      <rect x="0" y="0" width={wide} height={high} fill={MAP_UNDER_ROCK} />
      {drawn.flecks.map((f, n) => <circle key={`f${n}`} cx={mapNum(f.x)} cy={mapNum(f.y)} r={mapNum(f.r)} fill={f.light ? "#4A3F36" : "#1C1713"} />)}
      {drawn.coast && <path d={drawn.coast} fill="none" stroke="#6B5D4E" strokeOpacity={0.55} strokeWidth={1.2 / px} strokeDasharray={`${4 / px} ${3 / px}`} />}
      {/* the walls of every tunnel and cave first, then the floors over them, so where they meet they open into one */}
      <path d={drawn.walls} fill={MAP_UNDER_WALL} stroke={MAP_UNDER_WALL} strokeWidth={wall * 2} strokeLinejoin="round" />
      {drawn.tunnels.filter(t => t.hole).map(t => <circle key={`tw${t.n}`} cx={mapNum(t.hole[0])} cy={mapNum(t.hole[1])} r={mapNum(t.w / 2 + wall)} fill={MAP_UNDER_WALL} />)}
      {Object.entries(drawn.floors).map(([fill, d]) => <path key={fill} d={d} fill={fill} />)}
      {drawn.tunnels.filter(t => t.hole).map(t => <circle key={`ts${t.n}`} cx={mapNum(t.hole[0])} cy={mapNum(t.hole[1])} r={mapNum(t.w / 2)} fill="#050403" stroke={t.look.floor} strokeWidth={1 / px} />)}
      {Number(v.level) >= 3 && halls.map((h, n) => (
        <text key={`h${n}`} x={mapNum(h[1] / 10)} y={mapNum(h[2] / 10 - 10 / px)} textAnchor="middle" fontSize={mapNum(11 / px)} fontFamily={MAP_SERIF} fontStyle="italic"
          fill="#F1E8D6" stroke={MAP_UNDER_WALL} strokeOpacity={0.9} strokeWidth={mapNum(3 / px)} strokeLinejoin="round" style={{ paintOrder: "stroke" }}>{h[0]}</text>
      ))}
    </svg>
  );
}
// Metres down, told in feet (step 12d): 6,150 m is 20,180 feet.
const mapDownText = (m) => `${Math.round(Number(m) / 0.3048).toLocaleString("en-US")} feet down`;
// The battle grid under the ground (step 12d3; rpg_map_view: under.squares on the battle grid, rpg_session_state:
// board.parts): each open square by what it is, the rest solid rock. floor = the floor of a passage or a room, rubble
// = fallen rock (slow), pool = shallow water, column = a column of stone (no way through), shaft = climbed. The words
// are the one home of how the page names them; the colours of the Maps tab and the fight board alike.
const MAP_UNDER_PART = {
  floor: { fill: "#A99A82", words: "cave floor" },
  rubble: { fill: "#8C7D67", words: "fallen rock" },
  pool: { fill: "#6E9EB8", words: "a pool" },
  column: { fill: "#4A413A", words: "a column of stone, no way through" },
  shaft: { fill: "#5E5560", words: "a shaft, climbed" },
};
// The open squares under a battle grid (Maps tab), in place of the land (step 14a: a tunnel, not a block of squares):
// flecked rock; the floor of every open square as one shape with a soft, wandering wall (mapOutline, as the land's
// edges are drawn), a dark wall round it and a shadow along the inside of the wall; harder floor a little darker; pools
// their own soft shape, darker the deeper; stones on fallen rock, a boulder on a column, a dark hole for a shaft; the
// squares' lines faint on the floor only. The squares are the rules: a square is open or rock as the server says, the
// soft edge is the picture.
function MapUnderGrid({ v, px }) {
  const cols = Number(v.cols) || 12, rows = Number(v.rows) || 12, wide = cols * 100, high = rows * 100;
  const sq = v.under && Array.isArray(v.under.squares) ? v.under.squares : [];
  const lvl = Number(v.level) || 7, [x0, y0] = mapOrigin(v);
  const id = `rpg-under-${v.view || "grid"}`;
  const drawn = useMemo(() => {
    const at = {};
    sq.forEach(s => { if (Array.isArray(s)) at[`${s[0]},${s[1]}`] = s; });
    const wob = { lvl, x0, y0 };
    // the floor runs one ring past the grid where the squares at the edge are open, so a tunnel runs off the map
    const open = (i, j) => !!at[`${Math.min(Math.max(i, 0), cols - 1)},${Math.min(Math.max(j, 0), rows - 1)}`];
    const floor = sq.length ? mapOutline(cols, rows, open, 100, 0.35, wob) : "";
    const pool = sq.some(s => s[2] === "pool") ? mapOutline(cols, rows, (i, j) => { const s = at[`${i},${j}`]; return !!s && s[2] === "pool"; }, 100, 0.45, wob) : "";
    const lines = [];
    for (let i = 1; i < cols; i++) lines.push(mapLine([[i * 100, 0], [i * 100, high]]));
    for (let j = 1; j < rows; j++) lines.push(mapLine([[0, j * 100], [wide, j * 100]]));
    // harder floor darker, in soft patches as on the surface (mapHardShade): its percent of time, +400% the darkest
    const shade = mapHardShade(cols, rows, (i, j) => { const s = at[`${i},${j}`]; return s && (s[2] === "floor" || s[2] === "rubble") ? Math.min(Number(s[3]) || 0, 400) / 40 : null; }, 100, 0.45, "#1F1812", wob);
    // a pool darker the deeper, in soft patches: 0.9 m the darkest
    const deep = mapHardShade(cols, rows, (i, j) => { const s = at[`${i},${j}`]; return s && s[2] === "pool" ? Math.min(Number(s[4]) || 0, 1) * 10 : null; }, 100, 0.45, "#1E4B66", wob);
    return { at, floor, pool, shade, deep, grid: lines.join(""), flecks: mapUnderFlecks(wide, high, px, lvl, x0, y0) };
  }, [v, px]);
  return (
    <svg viewBox={`0 0 ${wide} ${high}`} preserveAspectRatio="none" aria-hidden="true"
      style={{ position: "absolute", left: 16, top: 16, width: "calc(100% - 16px)", height: "calc(100% - 16px)", borderRadius: 4, pointerEvents: "none", display: "block", overflow: "hidden" }}>
      <defs><clipPath id={id}><path d={drawn.floor} /></clipPath></defs>
      <rect x="0" y="0" width={wide} height={high} fill={MAP_UNDER_ROCK} />
      {drawn.flecks.map((f, n) => <circle key={`f${n}`} cx={mapNum(f.x)} cy={mapNum(f.y)} r={mapNum(f.r)} fill={f.light ? "#4A3F36" : "#1C1713"} />)}
      {drawn.floor && <path d={drawn.floor} fill="none" stroke={MAP_UNDER_WALL} strokeWidth={22} strokeLinejoin="round" />}
      {drawn.floor && <path d={drawn.floor} fill={MAP_UNDER_PART.floor.fill} />}
      <g clipPath={`url(#${id})`}>
        {drawn.shade.map((l, n) => <path key={`s${n}`} d={l.d} fill={l.fill} opacity={l.o * 1.6} />)}
        {drawn.pool && <path d={drawn.pool} fill={MAP_UNDER_PART.pool.fill} stroke="#4C7F9A" strokeWidth={6} />}
        {drawn.deep.map((l, n) => <path key={`p${n}`} d={l.d} fill={l.fill} opacity={l.o * 2} />)}
        <path d={drawn.floor} fill="none" stroke="#000" strokeOpacity={0.35} strokeWidth={46} strokeLinejoin="round" />
        <path d={drawn.grid} fill="none" stroke="#000" strokeOpacity={0.12} strokeWidth={Math.max(1, 1 / px)} />
      </g>
      {sq.map((s, n) => {
        if (!Array.isArray(s)) return null;
        const [i, j, part] = s, x = i * 100, y = j * 100, r = (k) => mapRand(lvl, x0 + i, y0 + j, k);
        if (part === "rubble") return <g key={`r${n}`}>{[0, 1, 2, 3, 4].map(k => <circle key={k} cx={x + 15 + 70 * r(710 + k)} cy={y + 15 + 70 * r(720 + k)} r={7 + 11 * r(730 + k)} fill="#6F6150" stroke="#3E352C" strokeWidth={3} />)}</g>;
        if (part === "column") return <path key={`c${n}`} d={mapStar(x + 50, y + 50, 40, 10, 0.86, r)} fill="#5B5149" stroke={MAP_UNDER_WALL} strokeWidth={6} />;
        if (part === "shaft") return <circle key={`h${n}`} cx={x + 50} cy={y + 50} r={36} fill="#050403" stroke="#3A322B" strokeWidth={6} />;
        return null;
      })}
    </svg>
  );
}
function MapArt({ art, px }) {
  const names = useMemo(() => mapNames(art.names, art.blocks, px, art.wide, art.high), [art, px]);
  return (
    <svg viewBox={`0 0 ${art.wide} ${art.high}`} preserveAspectRatio="none" aria-hidden="true"
      style={{ position: "absolute", left: 16, top: 16, width: "calc(100% - 16px)", height: "calc(100% - 16px)", borderRadius: 4, pointerEvents: "none", display: "block" }}>
      <MapStrokes layers={art.layers} px={px} unit={art.unit} />
      {art.aged && (
        <>
          <defs>
            <radialGradient id="rpg-map-edge" cx="50%" cy="50%" r="74%">
              <stop offset="60%" stopColor="#7A5A32" stopOpacity="0" />
              <stop offset="100%" stopColor="#7A5A32" stopOpacity="0.24" />
            </radialGradient>
          </defs>
          <rect x="0" y="0" width={art.wide} height={art.high} fill="url(#rpg-map-edge)" />
          <rect x={3 / px} y={3 / px} width={art.wide - 6 / px} height={art.high - 6 / px} fill="none" stroke={MAP_INK} strokeOpacity={0.5} strokeWidth={1 / px} />
        </>
      )}
      {names.map((n, k) => (
        <text key={k} x={mapNum(n.cx)} y={mapNum(n.cy + n.size * 0.34)} textAnchor="middle" fontSize={mapNum(n.size)}
          fontFamily={n.count ? "inherit" : MAP_SERIF} fontStyle={n.caps || n.count ? "normal" : "italic"} fontWeight={n.count ? 800 : n.caps ? 700 : 400}
          letterSpacing={n.caps && !n.north ? mapNum(n.size * 0.24) : undefined} fill={n.count ? MAP_PAPER.land : MAP_INK} opacity={n.caps ? 0.82 : 1}
          stroke={n.count ? "none" : MAP_PAPER.land} strokeOpacity={0.9} strokeWidth={mapNum(3.4 / px)} strokeLinejoin="round" style={{ paintOrder: "stroke" }}>{n.text}</text>
      ))}
    </svg>
  );
}
// A small square of the map for the lists and the key: one kind of ground or one place's symbol, in the fantasy
// style or, for the battle grid, seen from above. A place that only names the land shows a pennant of its color.
function MapSwatch({ what, color, size = 24, top }) {
  const layers = useMemo(() => {
    if (what === "unknown") return mapFog(1, 1, 100, () => true, 0, 1, 1, 0, 3, 5);
    // a house seen from above (step 8c), on a village street
    if (what === "house") return mapTop(1, 1, 3, 5, () => "village", [], true).concat(mapRoofs([{ x: 470, y: 470, ridge: [1000, 0], len: 840, wide: 500, roof: "thatch", eaves: 1.2 }], 100));
    if (top) return mapTop(1, 1, 3, 5, () => (MAP_ART.top[what] ? what : "plain"), color ? [{ d: "M0 0H100V100H0Z", fill: color, o: 0.14 }] : [], true);
    const out = [{ d: "M0 0H100V100H0Z", fill: mapWash(what) }];
    if (color) out.push({ d: "M0 0H100V100H0Z", fill: color, o: 0.3 });
    const rows = mapRows(12);
    const plain = what === "sea" || what === "land";
    const way = MAP_ROADS.find(r => what === "way" + r.k);
    if (way) out.push({ d: "M0 50H100", line: way.edge.line, units: 0, min: way.edge.min * 1.6, dash: way.edge.dash, cap: "butt" }, { d: "M0 50H100", line: way.mid.line, units: 0, min: (way.mid.min || 0) * 1.6 });
    // a bridge or a ford (step 11): the river across the square, the road down it, the crossing where they meet
    else if (what === "bridge" || what === "ford") out.push({ d: "M0 50Q50 36 100 50", line: MAP_RIVER, w: 3.2 }, { d: "M50 0V100", line: "#7A5A3A", w: 2 }, ...mapCrossing(50, 43, Math.PI / 2, 46, what === "bridge" ? 1 : 2, 4));
    else if (what === "road") out.push({ d: "M0 50H100", line: "#7A5A3A", w: 2, dash: [5, 3.5] });
    else if (MAP_ART.fantasy[what]) MAP_ART.fantasy[what](rows.add, plain ? 16 : 19, plain ? 16 : 27, plain ? 100 : 62, () => (plain ? 0.1 : 0.5), !plain);
    else if (color) out.push({ d: "M30 86V16", line: MAP_INK, w: 1.6 }, { d: "M30 18L78 30L30 46Z", fill: color, line: MAP_INK, w: 1.2 });
    return out.concat(rows.list(MAP_ART.ink));
  }, [what, color, top]);
  return (
    <svg viewBox="0 0 100 100" width={size} height={size} aria-hidden="true" style={{ flexShrink: 0, borderRadius: Math.round(size / 5), display: "block", border: `1px solid ${T.slate200}`, boxSizing: "border-box" }}>
      <MapStrokes layers={layers} px={size / 100} unit={top ? 100 : 40} />
    </svg>
  );
}
function MapsTab({ isParent, onError, onFight }) {
  const [at, setAt, atHref] = useTabParam("map", null);
  const [v, setV] = useState(null);
  const rootRef = useRef(null);
  // the grids already opened while this tab is up, so going back up the map is at once
  const seen = useRef(new Map());
  const wide = useElementWidth(rootRef) >= MAP_WIDE;
  // after a move on the journey every grid is read again (the pieces have moved); tick forces the read
  const [tick, setTick] = useState(0);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState(null);
  // what a tap on a cell does: open the grid inside it (null), walk the piece whose turn it is, or place a piece
  const [mode, setMode] = useState(null);
  useEffect(() => {
    let alive = true;
    const key = at || "";
    if (seen.current.has(key)) { setV(seen.current.get(key)); return undefined; }
    const m = /^(\d+)-(\d+)-(\d+)$/.exec(key);
    const place = /^p-([0-9a-f-]{36})$/.exec(key);
    const slid = /^s-(\d+)-(\d+)$/.exec(key);
    (async () => {
      const { data, error } = place ? await supabase.rpc("rpg_map_place_view", { p_place: place[1] })
        : slid ? await supabase.rpc("rpg_map_battle_view", { p_x0: Number(slid[1]), p_y0: Number(slid[2]) })
        : await supabase.rpc("rpg_map_view", m ? { p_level: Number(m[1]), p_x: Number(m[2]), p_y: Number(m[3]) } : {});
      if (!alive) return;
      if (error) { onError(error.message); if (at) setAt(null); return; }
      if (data) seen.current.set(key, data);
      setV(data || null);
    })();
    return () => { alive = false; };
  }, [at, setAt, onError, tick]);
  const act = useCallback(async (fn, args) => {
    if (busy) return;
    setBusy(true);
    const { data, error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) { onError(error.message); return; }
    setMode(null);
    setNote(data && typeof data === "object" && data.text ? data.text : null);
    seen.current.clear();
    setTick(t => t + 1);
  }, [busy, onError]);
  const j = v && v.journey && typeof v.journey === "object" ? v.journey : null;
  // a walk or a placing that no longer fits the journey (the turn passed, the piece left) is dropped
  const live = mode && j && (mode.kind === "place" ? (j.pieces || []).some(p => p.id === mode.id)
    : j.status === "active" && j.current === mode.id);
  const onCell = live ? (c) => {
    if (!Array.isArray(c.to)) return;
    if (mode.kind === "walk") act("rpg_map_walk", { p_participant_id: mode.id, p_x: c.to[0], p_y: c.to[1] });
    else act("rpg_place", { p_participant_id: mode.id, p_x: c.to[0], p_y: c.to[1] });
  } : null;
  const journey = v ? <MapJourney j={j} busy={busy} note={note} mode={live ? mode : null} setMode={setMode} act={act} atHref={atHref} setAt={setAt} onFight={onFight} isParent={isParent} /> : null;
  return (
    <div ref={rootRef} style={{ display: "grid", gridTemplateColumns: wide ? `${MAP_SIDE}px minmax(0, 1fr)` : "minmax(0, 1fr)", gap: 12, alignItems: "start" }}>
      {!v ? <div style={{ color: T.slate500, fontSize: 13 }}>Loading</div> : wide ? (
        <>
          <div style={{ minWidth: 0 }}>{journey}<MapSide v={v} atHref={atHref} setAt={setAt} order={0} /></div>
          <MapGrid v={v} atHref={atHref} setAt={setAt} journey={j} onCell={onCell} />
        </>
      ) : (
        <>
          {journey}
          <MapGrid v={v} atHref={atHref} setAt={setAt} journey={j} onCell={onCell} />
          <MapSide v={v} atHref={atHref} setAt={setAt} order={2} />
        </>
      )}
    </div>
  );
}
// The journey: the group walking the world map, turn by turn on one clock. No journey open → one button to start
// one. Otherwise the clock in words, every piece (where it is, when it goes next, its walking day), the controls for
// the piece whose turn it is, adding a character, and what happened. Everything shown comes from rpg_map_view.
function MapJourney({ j, busy, note, mode, setMode, act, atHref, setAt, onFight, isParent }) {
  const [pick, setPick] = useState("");
  if (!j) {
    return (
      <div style={{ ...card, marginBottom: 12 }}>
        <div style={label}>Journey</div>
        <div style={{ fontSize: 13, color: T.slate600, margin: "6px 0 10px" }}>{isParent ? "Walk the group across the map, one turn at a time." : "No journey yet. The game master starts one."}</div>
        {isParent && <button type="button" style={btn("primary")} disabled={busy} onClick={() => act("rpg_session_new", { p_name: null, p_on_map: true })}>Start a journey</button>}
      </div>
    );
  }
  const pieces = Array.isArray(j.pieces) ? j.pieces : [];
  const join = Array.isArray(j.can_join) ? j.can_join : [];
  const log = Array.isArray(j.log) ? j.log : [];
  const cur = j.status === "active" ? pieces.find(p => p.id === j.current) : null;
  const setup = j.status === "setup";
  const dot = (p, size = 12) => <span style={{ width: size, height: size, borderRadius: "50%", background: p.color || T.slate400, border: "2px solid #fff", boxShadow: `0 0 0 1px ${T.slate300}`, flexShrink: 0, display: "inline-block" }} />;
  return (
    <div style={{ ...card, marginBottom: 12, display: "grid", gridTemplateColumns: "minmax(0, 1fr)", gap: 10 }}>
      <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", gap: 8 }}>
        <span style={{ ...label, minWidth: 0 }}>{j.name}</span>
        <span style={{ fontSize: 13, fontWeight: 700, color: T.slate900, whiteSpace: "nowrap" }}>{j.time}</span>
      </div>
      {note && <div style={{ fontSize: 13, color: T.slate700, background: T.slate50, borderRadius: 8, padding: "7px 9px" }}>{note}</div>}
      {cur && (
        <div style={{ border: `1px solid ${T.blue}`, borderRadius: 10, padding: 10, display: "grid", gridTemplateColumns: "minmax(0, 1fr)", gap: 8 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 14, fontWeight: 700, color: T.slate900 }}>{dot(cur, 14)}{cur.name}’s turn</div>
          {cur.fight ? (
            <>
              <div style={{ fontSize: 12, color: T.slate600 }}>A fight is on. {cur.creature ? (isParent ? "The creature" : "The game master plays the creature; it") : cur.name} moves and acts on the fight board.</div>
              <div><button type="button" style={btn("primary", true)} onClick={() => onFight(j.id)}>Open the fight board</button></div>
            </>
          ) : cur.under ? (
            <>
              <div style={{ fontSize: 12, color: T.slate600 }}>{cur.under}. {cur.day_left} of walking left today.</div>
              {Array.isArray(cur.ways) && cur.ways.length > 0 ? (
                <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr)", gap: 6 }}>
                  {cur.ways.map(w => (
                    <button key={w[0]} type="button" disabled={busy} style={{ ...btn("soft", true), textAlign: "left", whiteSpace: "normal", lineHeight: 1.35 }}
                      onClick={() => act("rpg_map_under_walk", { p_participant_id: cur.id, p_to: w[0] })}>{w[1]}</button>
                  ))}
                </div>
              ) : (
                <div style={{ fontSize: 12, color: T.slate600 }}>No way on that anyone knows. Search here, or go back the way you came.</div>
              )}
              <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                {cur.mouth && <button type="button" disabled={busy} style={btn("primary", true)} onClick={() => act("rpg_map_under_leave", { p_participant_id: cur.id })}>Come up</button>}
                {cur.search && <button type="button" disabled={busy} style={btn("soft", true)} onClick={() => act("rpg_map_under_search", { p_participant_id: cur.id })}>Search for ways up · 1 h</button>}
                <button type="button" disabled={busy} style={btn("soft", true)} onClick={() => act("rpg_map_camp", { p_participant_id: cur.id })}>Camp 16 h</button>
                <button type="button" disabled={busy} style={btn("soft", true)} onClick={() => act("rpg_session_next_turn", { p_session_id: j.id })}>End turn</button>
              </div>
            </>
          ) : cur.placed ? (
            <>
              <div style={{ fontSize: 12, color: T.slate600 }}>{cur.day_left} of walking left today.</div>
              <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                <button type="button" disabled={busy} style={btn(mode && mode.kind === "walk" ? "primary" : "soft", true)}
                  onClick={() => setMode(mode && mode.kind === "walk" ? null : { kind: "walk", id: cur.id })}>{mode && mode.kind === "walk" ? "Tap the map…" : "Walk"}</button>
                {Array.isArray(cur.walk_to) && (
                  <button type="button" disabled={busy} style={btn("soft", true)}
                    onClick={() => act("rpg_map_walk", { p_participant_id: cur.id, p_x: cur.walk_to[0], p_y: cur.walk_to[1] })}>Keep walking · {cur.to_go}</button>
                )}
                {cur.cave && (
                  <button type="button" disabled={busy} style={btn("soft", true)} onClick={() => act("rpg_map_under_enter", { p_participant_id: cur.id })}>Go into {cur.cave}</button>
                )}
                <button type="button" disabled={busy} style={btn("soft", true)} onClick={() => act("rpg_map_camp", { p_participant_id: cur.id })}>Camp 16 h</button>
                <button type="button" disabled={busy} style={btn("soft", true)} onClick={() => act("rpg_session_next_turn", { p_session_id: j.id })}>End turn</button>
              </div>
            </>
          ) : (
            <div style={{ fontSize: 12, color: T.slate600 }}>Not on the map yet. Place it below, or end the turn.
              <button type="button" disabled={busy} style={{ ...btn("soft", true), marginLeft: 6 }} onClick={() => act("rpg_session_next_turn", { p_session_id: j.id })}>End turn</button>
            </div>
          )}
        </div>
      )}
      {mode && mode.kind === "place" && (
        <div style={{ fontSize: 13, color: T.slate700 }}>Tap the map to place {(pieces.find(p => p.id === mode.id) || {}).name}.
          <button type="button" style={{ ...btn("soft", true), marginLeft: 6 }} onClick={() => setMode(null)}>Cancel</button>
        </div>
      )}
      {pieces.length > 0 && (
        <div>
          {pieces.map(p => (
            <div key={p.id} style={{ display: "flex", alignItems: "center", gap: 8, padding: "7px 0", borderTop: `1px solid ${T.slate100}` }}>
              {dot(p)}
              <span style={{ minWidth: 0, flex: 1 }}>
                {p.find
                  ? <TabLink href={atHref(p.find)} onSelect={() => setAt(p.find)} style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>{p.name}</TabLink>
                  : <span style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>{p.name}</span>}
                <span style={{ display: "block", fontSize: 12, color: T.slate600 }}>
                  {[p.out || (p.creature ? "creature" : null), !p.placed ? "Not on the map" : p.under ? p.under : p.cell ? `On ${p.cell}` : "Elsewhere", p.fight && !p.creature ? "in a fight" : null, j.current === p.id && !setup ? "its turn" : p.next ? `next turn in ${p.next}` : null].filter(Boolean).join(" · ")}
                </span>
              </span>
              {isParent && (
                <button type="button" disabled={busy} style={btn(mode && mode.kind === "place" && mode.id === p.id ? "primary" : "soft", true)}
                  onClick={() => setMode(mode && mode.kind === "place" && mode.id === p.id ? null : { kind: "place", id: p.id })}>{p.placed ? "Move" : "Place"}</button>
              )}
            </div>
          ))}
        </div>
      )}
      {isParent && join.length > 0 && (
        <div style={{ display: "flex", gap: 6 }}>
          <select value={pick} onChange={e => setPick(e.target.value)} style={{ ...input, flex: 1, minWidth: 0 }}>
            <option value="">Add a character…</option>
            {join.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
          <button type="button" disabled={busy || !pick} style={btn("soft", true)}
            onClick={() => { act("rpg_session_add", { p_session_id: j.id, p_character_id: pick }); setPick(""); }}>Add</button>
        </div>
      )}
      {setup && isParent && (
        <button type="button" disabled={busy || !pieces.some(p => p.placed)} style={btn("primary")}
          onClick={() => act("rpg_session_next_turn", { p_session_id: j.id })}>{pieces.some(p => p.placed) ? "Begin the journey" : "Place someone to begin"}</button>
      )}
      <details>
        <summary style={{ ...label, cursor: "pointer" }}>What happened</summary>
        {log.map((t, k) => <div key={k} style={{ fontSize: 12, color: T.slate700, padding: "3px 0" }}>{t}</div>)}
        {isParent && (
          <button type="button" disabled={busy} style={{ ...btn("danger", true), marginTop: 8 }}
            onClick={() => { if (window.confirm("End this journey? Nothing more can happen in it.")) act("rpg_session_end", { p_session_id: j.id }); }}>End journey</button>
        )}
      </details>
    </div>
  );
}
// The sidebar: what this grid lists (the places one level down that reach into it), every other place, the grids.
function MapSide({ v, atHref, setAt, order }) {
  const places = Array.isArray(v.places) ? v.places : [];
  // the villages, towns and cities this grid shows (rpg_map_view: towns); the Region grid lists its towns and cities
  const towns = Array.isArray(v.towns) ? v.towns : [];
  const ladder = Array.isArray(v.ladder) ? v.ladder : [];
  const list = v.list && typeof v.list === "object" ? v.list : null;
  const listed = places.filter(p => p.listed).concat(towns.filter(t => t.listed));
  const others = places.filter(p => !p.listed);
  // the landmarks this grid shows (rpg_map_view: landmarks; step 12b), biggest first
  const marks = (Array.isArray(v.landmarks) ? v.landmarks : []).filter(p => !p.location);
  // and the places to go into (step 12c)
  const inside = (Array.isArray(v.landmarks) ? v.landmarks : []).filter(p => p.location);
  // the great halls of the Deeps under this grid (step 12d), from the Country grid down
  const halls = Number(v.level) >= 3 && v.under && Array.isArray(v.under.halls) ? v.under.halls : [];
  const row = (p, kind) => (
    <TabLink key={p.id} href={atHref(p.view || null)} onSelect={() => setAt(p.view || null)}
      style={{ display: "flex", gap: 10, alignItems: "flex-start", width: "100%", padding: "8px 0 0", borderTop: `1px solid ${T.slate100}`, marginTop: 8 }}>
      <MapSwatch what={p.icon} color={p.color} size={28} />
      <span style={{ minWidth: 0 }}>
        <span style={{ display: "block", fontSize: 13, fontWeight: 700, color: T.slate900 }}>{p.name}</span>
        <span style={{ display: "block", fontSize: 12, color: T.slate600 }}>{[kind ? p.level : null, p.size, p.ground, p.inside ? `in ${p.inside}` : null].filter(Boolean).join(" · ")}</span>
        {p.about && <span style={{ display: "block", fontSize: 12, color: T.slate500, marginTop: 2 }}>{p.about}</span>}
      </span>
    </TabLink>
  );
  return (
    <div style={{ order, minWidth: 0 }}>
      {list && (
        <div style={{ ...card, marginBottom: 12 }}>
          <div style={label}>{list.title}</div>
          {listed.length === 0 && <div style={{ fontSize: 12, color: T.slate500, marginTop: 6 }}>{list.empty}</div>}
          {listed.map(p => row(p, false))}
        </div>
      )}
      {others.length > 0 && <Fold title={`Other places (${others.length})`}>{others.map(p => row(p, true))}</Fold>}
      {marks.length > 0 && <Fold title={`Landmarks (${marks.length})`}>{marks.map(p => row(p, true))}</Fold>}
      {inside.length > 0 && <Fold title={`Places to go into (${inside.length})`}>{inside.map(p => row(p, true))}</Fold>}
      {halls.length > 0 && (
        <Fold title={`Great halls of the Deeps (${halls.length})`}>
          {halls.map(h => (
            <div key={h[0]} style={{ fontSize: 13, color: T.slate700, padding: "6px 0 0", borderTop: `1px solid ${T.slate100}`, marginTop: 6 }}>
              <b style={{ color: T.slate900 }}>{h[0]}</b> · {mapDownText(h[3])}
            </div>
          ))}
        </Fold>
      )}
      <Fold title="The grids">
        {ladder.map(l => (
          <div key={l.name} style={{ fontSize: 13, color: T.slate700, padding: "3px 0" }}><b style={{ color: T.slate900 }}>{l.name}.</b> {l.line}</div>
        ))}
        <div style={{ fontSize: 13, color: T.slate700, padding: "3px 0" }}>One square is {v.square}.</div>
      </Fold>
    </div>
  );
}
// The map itself. It is as wide as the space it gets, held to what the height of the screen can show whole. The
// picture (MapArt) lies under a grid of clear cells; each cell carries its name and what is in it, and opens the
// grid inside it. Under the map: the scale, then the key to the grounds and places drawn on this grid.
function MapGrid({ v, atHref, setAt, journey, onCell }) {
  const boxRef = useRef(null);
  // the Underground switch (step 12d): the passages under this grid, drawn over the dimmed land
  const [under, setUnder] = useState(false);
  const underLines = v.under && Array.isArray(v.under.lines) ? v.under.lines : [];
  const underHalls = v.under && Array.isArray(v.under.halls) ? v.under.halls : [];
  // on the battle grid the squares under it (step 12d3)
  const underSquares = v.under && Array.isArray(v.under.squares) ? v.under.squares : [];
  // every grid from the Continent grid down has a world under it, even where it is solid rock (step 14a2)
  const hasUnder = !!(v.under && typeof v.under === "object");
  // the one whose turn it is stands under the ground on this battle grid: show it underground (step 12d3)
  const curUnder = !!(journey && Array.isArray(journey.pieces) && underSquares.length > 0
    && journey.pieces.some(p => p.id === journey.current && p.under && Array.isArray(p.spot)));
  useEffect(() => { if (curUnder) setUnder(true); }, [curUnder]);
  const underAt = {};
  underSquares.forEach(s => { if (Array.isArray(s)) underAt[`${s[0] + 1},${s[1] + 1}`] = s; });
  const width = useElementWidth(boxRef);
  const level = Number(v.level) || 1;
  const cols = Number(v.cols) || 12;
  const cells = Array.isArray(v.cells) ? v.cells : [];
  const places = Array.isArray(v.places) ? v.places : [];
  const crumbs = Array.isArray(v.crumbs) ? v.crumbs : [];
  const within = Array.isArray(v.within) ? v.within : [];
  const moves = v.slides && typeof v.slides === "object" ? v.slides : v.moves && typeof v.moves === "object" ? v.moves : null;
  const slides = !!(v.slides && typeof v.slides === "object");
  const grounds = v.grounds && typeof v.grounds === "object" ? v.grounds : {};
  const detail = v.detail && Array.isArray(v.detail.cells) ? v.detail : null;
  // the last grid of the ladder is the battle grid, seen from above
  const top = Array.isArray(v.ladder) && v.ladder.length > 0 && level === v.ladder.length;
  // the place cards and the villages, towns and cities (rpg_map_view: towns), by id: cells name both the same way
  const towns = Array.isArray(v.towns) ? v.towns : [];
  const byId = useMemo(() => { const all = {}; (Array.isArray(v.places) ? v.places : []).concat(Array.isArray(v.towns) ? v.towns : [], Array.isArray(v.landmarks) ? v.landmarks : []).forEach(p => { all[p.id] = p; }); return all; }, [v]);
  // the land is not drawn while the Underground switch shows the world under the ground in its place (step 14a)
  const art = useMemo(() => (under && hasUnder ? null : (top ? mapBattle : mapFantasy)(v, byId)), [v, byId, top, under, hasUnder]);
  // how many screen pixels one unit of the drawing takes (a cell is 100 units)
  const px = width > 16 ? (width - 16) / (cols * 100) : 1;
  const ground = (k) => { const g = grounds[k]; return g && typeof g === "object" ? [g.name, g.penalty].filter(Boolean).join(" · ") : String(g || k); };
  const drawn = new Set(detail && Array.isArray(detail.places) ? detail.places : []);
  if (detail && detail.marks && typeof detail.marks === "object") Object.values(detail.marks).forEach(l => (Array.isArray(l) ? l : []).forEach(id => drawn.add(id)));
  const axis = { fontSize: 10, color: T.slate500, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" };
  const grid = [<div key="corner" />];
  for (let x = 1; x <= cols; x++) grid.push(<div key={`c${x}`} style={axis}>{String.fromCharCode(64 + x)}</div>);
  cells.forEach(c => {
    if (c.x === 1) grid.push(<div key={`r${c.y}`} style={axis}>{c.y}</div>);
    const p = c.place ? byId[c.place] : null;
    const marks = (Array.isArray(c.marks) ? c.marks : []).map(id => byId[id]).filter(Boolean);
    if (p) drawn.add(p.id);
    marks.forEach(k => drawn.add(k.id));
    // a square something built stands on (step 8c: a house; step 12b2: a landmark), climbed (climb: part, metres,
    // degrees, difficulty, what it is in words)
    const climb = Array.isArray(c.climb) ? `${c.climb[4]}, ${c.climb[1]} m up, climbed (Climbing against ${c.climb[3]})`
      // a square of a place to go into walked like the ground (step 12c)
      : c.feature ? ({ floor: "a floor", hearth: "a hearth", altar: "an altar", mouth: "the way in, underground" })[c.feature] || null : null;
    const u = under && top ? underAt[`${c.x},${c.y}`] : null;
    const title = under && top && hasUnder
      ? `${c.name} · under the ground: ${u ? `${(MAP_UNDER_PART[u[2]] || MAP_UNDER_PART.floor).words}${u[4] ? `, ${u[4]} m deep` : ""}${u[3] != null ? ` · +${u[3]}% time a square` : ""} · ${Number(u[5]).toLocaleString("en-US")} feet down` : "solid rock"}`
      : `${c.name} · ${climb ? `${climb} · ` : ""}${p ? [p.name, p.ground].filter(Boolean).join(" · ") : ground(c.kind)}${c.cost != null ? ` · this ${top ? "square" : "cell"}: +${c.cost}% time a square` : ""}${marks.length ? ` · also here: ${marks.map(k => k.name).join(", ")}` : ""}`;
    const style = { aspectRatio: "1 / 1", minWidth: 0, padding: 0, margin: 0, boxSizing: "border-box", position: "relative", display: "block", cursor: c.open || onCell ? "pointer" : "default" };
    grid.push(onCell
      ? <button key={c.name} type="button" onClick={() => onCell(c)} title={title} aria-label={title} className="rpg-map-cell" style={{ ...style, background: "none", border: "none" }} />
      : c.open
        ? <TabLink key={c.name} href={atHref(c.open)} onSelect={() => setAt(c.open)} title={title} ariaLabel={title} className="rpg-map-cell" style={style} />
        : <div key={c.name} title={title} style={style} />);
  });
  // the pieces of the open journey that stand on this grid, at their spot (thousandths of a cell from the top-left
  // corner); pieces sharing a cell sit side by side, and the one whose turn it is wears a ring
  const rows = Number(v.rows) || 12;
  const pieces = journey && Array.isArray(journey.pieces) ? journey.pieces.filter(p => Array.isArray(p.spot)) : [];
  const shared = {};
  const tokens = pieces.map(p => {
    const k = `${Math.floor(p.spot[0] / 1000)},${Math.floor(p.spot[1] / 1000)}`;
    const n = shared[k] = (shared[k] || 0) + 1;
    const turn = journey.status === "active" && journey.current === p.id;
    return (
      <span key={p.id} title={p.under ? `${p.name} · ${p.under}` : p.name} aria-hidden="true"
        style={{ position: "absolute", left: `calc(16px + (100% - 16px) * ${p.spot[0] / (cols * 1000)} + ${(n - 1) * 12}px)`, top: `calc(16px + (100% - 16px) * ${p.spot[1] / (rows * 1000)})`,
          transform: "translate(-50%, -50%)", width: 22, height: 22, background: p.color || T.slate500, border: p.under ? "2px dashed #fff" : "2px solid #fff",
          boxShadow: turn ? `0 0 0 3px ${T.blue}, 0 1px 3px rgba(0,0,0,.4)` : "0 1px 3px rgba(0,0,0,.4)", color: "#fff", fontSize: 11, fontWeight: 800,
          borderRadius: p.creature ? 5 : "50%", borderColor: p.creature ? "#5A1E1E" : "#fff", opacity: p.out ? 0.4 : 1,
          display: "flex", alignItems: "center", justifyContent: "center", pointerEvents: "none", boxSizing: "border-box", zIndex: turn ? 3 : 2 }}>
        {String(p.name || "?").charAt(0)}
      </span>
    );
  });
  const kinds = MAP_GROUNDS.filter(([k, ch]) => cells.some(c => c.kind === k) || (detail && detail.cells.some(row => String(row).includes(ch)))).map(([k]) => k);
  const shown = places.filter(p => drawn.has(p.id) && !p.listed);
  // each kind of village, town and city drawn here, once in the key, then what their streets cost
  const townKinds = ["great_city", "city", "town", "village"].map(k => towns.find(t => t.kind === k && drawn.has(t.id))).filter(Boolean);
  // each kind of landmark drawn here (step 12b), once, biggest first
  const landKinds = (Array.isArray(v.landmarks) ? v.landmarks : []).filter(l => drawn.has(l.id)).filter((l, n, all) => all.findIndex(o => o.level === l.level) === n);
  // the sizes of road drawn here (rpg_map_view: roads), then what a road and a mountain road cost
  const ways = MAP_ROADS.slice().reverse().filter(r => (Array.isArray(v.roads) ? v.roads : []).some(p => Array.isArray(p) && p[0] === r.k));
  // the bridges and fords drawn here (step 11): on the fantasy map the crossings, on the battle grid the squares
  const crosses = ["bridge", "ford"].filter(k => (Array.isArray(v.crossings) ? v.crossings : []).some(c => Array.isArray(c) && MAP_CROSSINGS[c[0]] === (k === "bridge" ? "Bridge" : "Ford")) || cells.some(c => c.cross === k));
  const costly = kinds.some(k => grounds[k] && grounds[k].penalty) || shown.some(p => /%/.test(p.ground || "")) || townKinds.length > 0 || ways.length > 0;
  return (
    <div style={{ ...card, order: 1, minWidth: 0, display: "grid", gap: 10 }}>
      <style>{".rpg-map-cell:hover{box-shadow:inset 0 0 0 2px rgba(75,59,42,.6);border-radius:3px}"}</style>
      <div style={{ display: "flex", alignItems: "center", gap: 6, flexWrap: "wrap" }}>
        {crumbs.map((k, i) => (i === crumbs.length - 1
          ? <span key={i} style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{k.label}</span>
          : (
            <span key={i} style={{ display: "flex", alignItems: "center", gap: 6 }}>
              <TabLink href={atHref(k.view || null)} onSelect={() => setAt(k.view || null)} style={{ fontSize: 14, fontWeight: 600, color: T.blue }}>{k.label}</TabLink>
              <span style={{ color: T.slate400 }}>›</span>
            </span>
          )))}
        {hasUnder && (
          <button type="button" onClick={() => setUnder(u => !u)} aria-pressed={under} title="Show the caves, mines and the Deeps under this grid"
            style={{ ...btn(under ? "primary" : "soft", true), marginLeft: "auto" }}>Underground</button>
        )}
        {moves && (
          <div style={{ display: "flex", gap: 4, marginLeft: hasUnder ? 0 : "auto" }}>
            {MAP_MOVES.map(([k, t]) => (
              <TabLink key={k} href={atHref(moves[k] || null)} onSelect={() => setAt(moves[k])} disabled={!moves[k]} title={slides ? `Slide half a grid ${k}` : `The next grid ${k}`} ariaLabel={slides ? `Slide half a grid ${k}` : `The next grid ${k}`}
                style={{ ...btn("soft", true), minWidth: 30, textAlign: "center", opacity: moves[k] ? 1 : 0.35 }}>{t}</TabLink>
            ))}
          </div>
        )}
      </div>
      <div ref={boxRef} style={{ width: `min(100%, max(340px, calc((100dvh - 300px) * ${cols / (Number(v.rows) || 12)} + 16px)))`, margin: "0 auto", userSelect: "none" }}>
        <div style={{ position: "relative", display: "grid", gridTemplateColumns: `16px repeat(${cols}, minmax(0, 1fr))`, gridTemplateRows: "16px" }}>
          {art && <MapArt art={art} px={px} />}
          {under && hasUnder && (top ? <MapUnderGrid v={v} px={px} /> : <MapUnder v={v} px={px} />)}
          {grid}
          {tokens}
        </div>
      </div>
      <div style={{ display: "flex", gap: "6px 14px", flexWrap: "wrap", alignItems: "center", fontSize: 12, color: T.slate600 }}>
        <span>{within.length > 0 ? `In ${within.slice().reverse().join(", ")}. ` : ""}{v.scale}{onCell ? " Tap a cell: the piece goes to its middle." : cells.some(c => c.open) ? " Tap a cell to open the grid inside it." : ""}</span>
        {shown.map(p => (
          <TabLink key={p.id} href={atHref(p.view || null)} onSelect={() => setAt(p.view || null)} style={{ display: "flex", alignItems: "center", gap: 5, color: T.slate700, fontWeight: 600 }}>
            <MapSwatch what={p.icon} color={p.color} size={20} top={top} />{p.name}{p.ground && <span style={{ fontWeight: 400, color: T.slate600 }}>· {p.ground}</span>}
          </TabLink>
        ))}
        {townKinds.map(t => (
          <span key={t.kind} style={{ display: "flex", alignItems: "center", gap: 5 }}>
            <MapSwatch what={t.icon} color={t.color} size={20} top={top} />{t.level}
          </span>
        ))}
        {townKinds.length > 0 && townKinds[0].ground && <span>Their streets and yards: {townKinds[0].ground}.</span>}
        {landKinds.map(l => (
          <span key={l.level} style={{ display: "flex", alignItems: "center", gap: 5 }}>
            <MapSwatch what={l.icon} size={20} />{l.level}
          </span>
        ))}
        {landKinds.length > 0 && <span>Landmarks are seen from far off: a keep 100 feet tall from about 13 miles. The list beside the map says how far for each.</span>}
        {under && hasUnder && !top && ["deep", "cave", "own", "join"].filter(k => underLines.some(l => l[0] === k || (k === "join" && l[0] === "delve"))).map(k => (
          <span key={`u${k}`} style={{ display: "flex", alignItems: "center", gap: 5 }}>
            <svg width="24" height="12" aria-hidden="true"><rect width="24" height="12" rx="2" fill={MAP_UNDER_ROCK} /><path d="M2 6H22" stroke={MAP_UNDER_WALL} strokeWidth="7" strokeLinecap="round" /><path d="M2 6H22" stroke={MAP_UNDER[k].floor} strokeWidth={k === "join" ? 2.5 : 4.5} strokeLinecap="round" /></svg>
            {MAP_UNDER[k].words}
          </span>
        ))}
        {under && hasUnder && !top && underLines.some(l => l[0] === "shaft") && <span>A dark hole: a shaft from a great hall up into the cave country over it.</span>}
        {under && hasUnder && !top && cells.some(c => c.kind === "sea") && <span>Dashed: the coast above.</span>}
        {under && hasUnder && !top && level <= 3 && <span>The Deeps alone at this size: caves and mines show from the Region grid down.</span>}
        {under && top && underSquares.length === 0 && <span>Solid rock: no passage runs under this battle grid. The arrows slide it half a grid.</span>}
        {under && top && underSquares.length > 0 && (
          <>
            <span style={{ display: "flex", alignItems: "center", gap: 5 }}>
              <span style={{ width: 14, height: 14, borderRadius: 3, background: MAP_UNDER_ROCK, display: "inline-block" }} />Solid rock: no way in.
            </span>
            {["under_deep", "under_cave", "under_mine", "under_squeeze"].filter(k => grounds[k]).map(k => (
              <span key={k}>{ground(k)}.</span>
            ))}
            {["rubble", "pool", "column", "shaft"].filter(k => underSquares.some(s => s[2] === k)).map(k => (
              <span key={k} style={{ display: "flex", alignItems: "center", gap: 5 }}>
                <span style={{ width: 14, height: 14, borderRadius: 3, background: MAP_UNDER_PART[k].fill, display: "inline-block" }} />
                {({ rubble: "Fallen rock: the slowest floor.", pool: "A pool: waded, slower the deeper.", column: "A column of stone: no way through.", shaft: "A shaft: climbed." })[k]}
              </span>
            ))}
          </>
        )}
        {Array.isArray(v.houses) && v.houses.length > 0 && (
          <span style={{ display: "flex", alignItems: "center", gap: 5 }}>
            <MapSwatch what="house" size={20} />Houses: their walls and roofs are climbed (see Climbing); a walk goes round them.
          </span>
        )}
        {cells.some(c => c.feature === "mouth") && (
          <span style={{ display: "flex", alignItems: "center", gap: 5 }}>
            <span style={{ width: 14, height: 14, borderRadius: 4, background: MAP_FEATURE.mouth.fill, display: "inline-block" }} />The way into a cave or a mine: it leads underground.
          </span>
        )}
        {cells.some(c => Array.isArray(c.climb) && MAP_BUILT[c.climb[0]]) && (
          <span>Walls, towers, standing stones and boulders are climbed too (see Climbing): a castle wall 40 feet high is sheer, Climbing against 10; a walk goes round them.</span>
        )}
        {ways.map(r => (
          <span key={r.k} style={{ display: "flex", alignItems: "center", gap: 5 }}>
            <MapSwatch what={"way" + r.k} size={20} />{r.name}
          </span>
        ))}
        {ways.length > 0 && grounds.road && <span>On a road: {grounds.road.penalty}{grounds.pass && grounds.pass.penalty ? `; over mountains: ${grounds.pass.penalty}` : ""}. A walk keeps to the roads where they serve.</span>}
        {crosses.map(k => (
          <span key={k} style={{ display: "flex", alignItems: "center", gap: 5 }}>
            <MapSwatch what={k} size={20} top={top} />{k === "bridge" ? "Bridge: the road carried over the water" : "Ford: the water is knee-deep here (+50% a square), waded; a walk sent through one needs no swim"}
          </span>
        ))}
        {kinds.map(k => (
          <span key={k} style={{ display: "flex", alignItems: "center", gap: 5 }}>
            <MapSwatch what={k} size={20} top={top} />{ground(k)}
          </span>
        ))}
        {costly && <span>Each square adds its own share of time to cross it, inside its ground's range; darker is harder. At +60% a square takes 5 × 1.6 = 8 ticks instead of 5 at Speed 10.</span>}
        {(cells.some(c => c.kind === "unknown") || (detail && detail.cells.some(row => String(row).includes("?")))) && <span style={{ display: "flex", alignItems: "center", gap: 5 }}><MapSwatch what="unknown" size={20} />Not found yet</span>}
      </div>
    </div>
  );
}

// A picture for the card. Pictures live in the private rpg-images bucket: the family login, owner
// and admin can see them (rpg_can_play, 2026-10-04), parents upload. No picture yet → a parent gets an upload control and a ready-made
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

function FightView({ id, isParent, defs, onBack, backHref, onError, onMap }) {
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
  // a fight on a journey belongs to the map: it starts when a creature is met and the journey ends from the Maps tab
  const journey = !!s.on_map;
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
        {journey && onMap
          ? <button type="button" style={btn("soft", true)} onClick={onMap}>‹ Map</button>
          : <TabLink href={backHref} onSelect={onBack} style={btn("soft", true)}>‹ All fights</TabLink>}
        <div style={{ fontSize: 18, fontWeight: 700, color: T.slate900, minWidth: 0, flex: "1 1 auto" }}>{s.name}{ended ? " · over" : ""}</div>
        {isParent && !ended && (
          <button type="button" style={btn(adding || setup ? "primary" : "soft", true)} onClick={() => setAdding(!adding)}>{adding || setup ? "Adding" : "Add someone"}</button>
        )}
        {isParent && setup && !journey && (
          <button type="button" style={btn("primary", true)} disabled={busy || parts.length === 0} onClick={endTurn}>Start the fight</button>
        )}
        {isParent && !ended && !journey && (
          <button type="button" style={btn("soft", true)} disabled={busy}
            onClick={() => { if (window.confirm("End this fight? Nothing more can happen in it.")) run("rpg_session_end", { p_session_id: id }); }}>End fight</button>
        )}
        {isParent && ended && !journey && <button type="button" style={btn("danger", true)} onClick={del}>Delete fight</button>}
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
// The fight board, built from rpg_session_state: the world map under the fight, round the one whose turn it is
// (board: its first square, size, column and row names within each battle grid, the percent of time each square adds,
// forest, fire and sea). Squares are shaded by that percent (the number sits in the corner), green when forest, orange
// while burning, blue for sea; everyone on their square. On the turn of someone you act for, the squares they can
// still reach this turn are ringed, with the ticks each costs; tap one to move there (rpg_act_square). A card action
// aimed at a square (Briar Shift, a Torch's Light the ground) waits here for its square. The game master can move a
// fighter by hand (rpg_place) and set fire or put it out (rpg_set_square). A fight off the map has no board.
function FightGrid({ st, isParent, actor, ended, busy, run, pending, onPending }) {
  const s = st?.session || {};
  const b = s.board && typeof s.board === "object" ? s.board : null;
  const parts = Array.isArray(st?.participants) ? st.participants : [];
  const moves = Array.isArray(st?.moves) ? st.moves : [];
  const [mode, setMode] = useState("move");
  const [who, setWho] = useState("");
  if (ended) return null;
  if (!b) {
    return isParent && s.on_map === false && parts.length > 0
      ? <div style={{ ...card, fontSize: 12, color: T.slate600 }}>This fight is off the map, so there is no board and everyone is in reach. Fights on the ground happen on a journey.</div>
      : null;
  }
  const w = Number(b.w) || 0;
  const h = Number(b.h) || 0;
  const x0 = Number(b.x0) || 1;
  const y0 = Number(b.y0) || 1;
  const sqs = Array.isArray(b.squares) ? b.squares : [];
  const cols = Array.isArray(b.cols) ? b.cols : [];
  const rows = Array.isArray(b.rows) ? b.rows : [];
  const away = b.away && typeof b.away === "object" ? b.away : {};
  const at = {};
  parts.filter(p => p.pos_x != null).forEach(p => { at[`${p.pos_x},${p.pos_y}`] = p; });
  const moveAt = {};
  if (actor && !pending && mode === "move") moves.forEach(m => { moveAt[`${m.x},${m.y}`] = m; });
  const pick = parts.some(p => p.id === who) ? who : (parts[0]?.id || "");
  const nameOf = (x, y) => `${cols[x - x0] || ""}${rows[y - y0] || ""}`;
  const click = (x, y, g) => {
    if (busy) return;
    if (pending) {
      run("rpg_act_square", { p_actor_id: pending.actorId, p_x: x, p_y: y, p_action_id: pending.actionId }, pending.actorId).then(r => { if (r) onPending(null); });
      return;
    }
    if (isParent && mode === "place") { if (pick) run("rpg_place", { p_participant_id: pick, p_x: x, p_y: y }); return; }
    if (isParent && mode === "fire") { run("rpg_set_square", { p_session_id: s.id, p_x: x, p_y: y, p_burning: !g[2] }); return; }
    if (moveAt[`${x},${y}`]) run("rpg_act_square", { p_actor_id: actor.id, p_x: x, p_y: y }, actor.id);
  };
  const axis = { fontSize: 10, color: T.slate500, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" };
  const cells = [<div key="corner" />];
  for (let i = 0; i < w; i++) cells.push(<div key={`c${i}`} style={axis}>{cols[i]}</div>);
  for (let j = 0; j < h; j++) {
    cells.push(<div key={`r${j}`} style={axis}>{rows[j]}</div>);
    for (let i = 0; i < w; i++) {
      const x = x0 + i, y = y0 + j;
      const k = `${x},${y}`;
      const g = Array.isArray(sqs[j * w + i]) ? sqs[j * w + i] : [0, false, false, false];
      const p = at[k];
      const m = moveAt[k];
      const sea = !!g[3];
      // under the ground (step 12d3) the no-way-in squares are rock, and each open one says what it is
      const below = typeof b.under === "string";
      const part = below && Array.isArray(b.parts) ? b.parts[j * w + i] : null;
      const look = part ? MAP_UNDER_PART[part] : null;
      const n = Number(g[0]) || 0;
      const steps = Math.min(n, 600) / 100;
      const forest = !!g[1];
      const fire = !!g[2];
      const title = `${nameOf(x, y)}${sea ? (below ? (part === "column" ? ` · ${MAP_UNDER_PART.column.words}` : " · solid rock") : " · sea") : look ? ` · ${look.words}` : ""}${n ? ` · +${n}% time to cross` : ""}${forest ? " · forest" : ""}${fire ? ` · burning (+${s.burn_cost}% more to step into)` : ""}${p ? ` · ${p.name}${p.out ? ` (${p.out})` : ""}` : ""}${m ? ` · ${m.ticks} ticks to get here` : ""}`;
      const live = pending || (isParent && mode !== "move") || m;
      cells.push(
        <button key={k} type="button" title={title} onClick={() => click(x, y, g)}
          style={{ aspectRatio: "1 / 1", minWidth: 0, padding: 0, margin: 0, position: "relative", borderRadius: 3, fontFamily: "inherit",
                   border: m ? `2px solid ${T.blue}` : `1px solid ${T.slate200}`, cursor: live ? "pointer" : "default",
                   background: below && sea ? (part === "column" ? MAP_UNDER_PART.column.fill : MAP_UNDER_ROCK) : sea ? "#B9D3DE" : fire ? `hsl(24, 90%, ${86 - steps * 6}%)` : forest ? `hsl(130, 32%, ${88 - steps * 8}%)`
                     : look && part !== "floor" ? look.fill : below ? `hsl(36, 16%, ${80 - steps * 8}%)` : n > 0 ? `hsl(75, 28%, ${92 - steps * 9}%)` : T.slate50,
                   display: "flex", alignItems: "center", justifyContent: "center" }}>
          {n > 0 && <span style={{ position: "absolute", top: 0, left: 2, fontSize: 8, lineHeight: 1.2, color: n >= 300 || (below && part !== "floor") ? T.white : T.slate600 }}>{n}</span>}
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
  const far = parts.filter(p => p.pos_x != null && away[p.id] != null);
  const off = parts.filter(p => p.pos_x == null);
  const under = typeof b.under === "string" ? b.under : null;
  return (
    <div style={{ ...card, display: "grid", gap: 10 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
        <div style={label}>Board</div>
        {under && <div style={{ fontSize: 12, color: T.slate700, fontWeight: 600 }}>{under}. Dark squares are solid rock.</div>}
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
          {[["move", "Move"], ["place", "Place"], ["fire", "🔥 Fire"]].map(([k, t]) => (
            <button key={k} type="button" style={btn(mode === k ? "primary" : "soft", true)} onClick={() => setMode(k)}
              title={k === "fire" ? `Tap a square to set it alight for ${s.burn_rounds} rounds, or to put it out` : undefined}>{t}</button>
          ))}
          {mode === "place" && (
            <select style={input} value={pick} onChange={e => setWho(e.target.value)}>
              {parts.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          )}
        </div>
      )}
      <div style={{ display: "grid", gridTemplateColumns: `16px repeat(${w}, minmax(0, 1fr))`, gap: 1, width: "100%", maxWidth: 32 * w + 16, userSelect: "none" }}>
        {cells}
      </div>
      {far.length > 0 && (
        <div style={{ fontSize: 12, color: T.slate600 }}>Farther off: {far.map(p => `${p.name} (${away[p.id]} squares)`).join(", ")}.</div>
      )}
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
