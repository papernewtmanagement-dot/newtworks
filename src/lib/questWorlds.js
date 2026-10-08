// =========================================================================
// questWorlds.js — the story, worlds, levels and monsters of Spelling Quest's
// Monsters mode. Pure data plus the functions that turn it into a level.
//
// The story: the Great Word Book kept every word in the land bright. Grumblegloom,
// a dragon who hates noise, tore out its ten pages and hid one in each corner of
// the land, and the monsters woke up. Spell your way through ten worlds, win back
// each page from the boss guarding it, and give the land its words back.
//
// 10 worlds x 10 levels = 100 levels, numbered 1–100 across the worlds. A level
// is 2 to 4 monsters; level 10 of each world ends in that world's boss.
// Adding a world later: add a WORLDS entry and its five MONSTERS.
// =========================================================================

export const LEVELS_PER_WORLD = 10;

// look: body shape (round, blob, tall, wide, bug); bits: add-ons drawn on top.
// power: stone = may turn one of your letters to stone for 3 turns when it hits;
//        heal  = mends itself a little every third turn.
export const MONSTERS = {
  // 1 Dusty Library
  dustbunny:   { name: "Dust Bunny",      body: "#C9C2B8", look: "round", bits: ["ears"], mouth: "smile" },
  inkblot:     { name: "Ink Blot",        body: "#4A477E", look: "blob",  bits: [], eyes: 1, mouth: "o" },
  papermoth:   { name: "Paper Moth",      body: "#D9C9A3", look: "bug",   bits: ["wings", "antennae"], mouth: "smile" },
  pagemite:    { name: "Page Mite",       body: "#A8875E", look: "wide",  bits: ["antennae"], eyes: 3, mouth: "fangs" },
  ratking:     { name: "Riddle Rat King", body: "#8C7B6B", look: "round", bits: ["ears", "crown", "tail"], mouth: "fangs", boss: true, power: "heal" },
  // 2 Whispering Woods
  mosstoad:    { name: "Moss Toad",       body: "#5E8C6A", look: "wide",  bits: ["spots"], mouth: "frown" },
  thornsprite: { name: "Thorn Sprite",    body: "#9BC46A", look: "tall",  bits: ["wings", "spikes"], mouth: "smile" },
  acorngrub:   { name: "Acorn Grub",      body: "#B07A3E", look: "round", bits: ["cap"], mouth: "o" },
  spellslug:   { name: "Spell Slug",      body: "#8DBA5E", look: "blob",  bits: ["antennae"], mouth: "smile", power: "stone" },
  gnomechief:  { name: "Grumble Gnome Chief", body: "#6E8B4E", look: "tall", bits: ["hat", "beard"], mouth: "frown", boss: true, power: "heal" },
  // 3 Glimmer Caves
  crystalbat:  { name: "Crystal Bat",     body: "#6C5B9C", look: "round", bits: ["wings", "ears"], mouth: "fangs" },
  shroomp:     { name: "Shroomp",         body: "#E8D9C4", look: "tall",  bits: ["cap"], mouth: "smile" },
  echoghost:   { name: "Echo Ghost",      body: "#E8E6F2", look: "blob",  bits: [], eyes: 2, mouth: "o" },
  rockling:    { name: "Rockling",        body: "#8A8478", look: "wide",  bits: ["crystals"], mouth: "frown", power: "stone" },
  stonetroll:  { name: "Stone Troll",     body: "#7A6A8C", look: "wide",  bits: ["horns", "crystals"], mouth: "fangs", boss: true, power: "stone" },
  // 4 Stormy Sea
  pufferpest:  { name: "Puffer Pest",     body: "#E2B13C", look: "round", bits: ["spikes", "fins"], mouth: "o" },
  crabclack:   { name: "Crab Clacker",    body: "#D2553E", look: "wide",  bits: ["claws"], mouth: "smile" },
  squidscrib:  { name: "Squid Scribbler", body: "#B86FA8", look: "tall",  bits: ["tentacles"], mouth: "o", power: "stone" },
  barnacle:    { name: "Barnacle Blob",   body: "#7FA6A0", look: "blob",  bits: ["spots"], eyes: 3, mouth: "frown" },
  kraken:      { name: "Captain Kraken Quill", body: "#3E6E8C", look: "tall", bits: ["tentacles", "hat"], mouth: "fangs", boss: true, power: "heal" },
  // 5 Sandscript Desert
  scorpling:   { name: "Sand Scorpling",  body: "#D9A55B", look: "wide",  bits: ["claws", "tail"], mouth: "fangs" },
  cactuscrank: { name: "Cactus Crank",    body: "#6E9B4E", look: "tall",  bits: ["spikes"], mouth: "frown" },
  dustdevil:   { name: "Dust Devil",      body: "#C9A27A", look: "blob",  bits: ["horns"], mouth: "smile" },
  scarab:      { name: "Riddle Scarab",   body: "#2E7A6E", look: "bug",   bits: ["antennae"], eyes: 3, mouth: "o", power: "stone" },
  dunesphinx:  { name: "Dune Sphinx",     body: "#E2B13C", look: "wide",  bits: ["ears", "crown", "tail"], mouth: "smile", boss: true, power: "heal" },
  // 6 Frostbite Peaks
  snowpuff:    { name: "Snow Puff",       body: "#F4F7FA", look: "round", bits: ["ears"], mouth: "o" },
  iceimp:      { name: "Ice Imp",         body: "#8CCFF2", look: "tall",  bits: ["horns", "wings"], mouth: "fangs" },
  frostowl:    { name: "Frost Owl",       body: "#B9C7D6", look: "round", bits: ["wings", "ears"], mouth: "o" },
  yeticub:     { name: "Yeti Cub",        body: "#E8E6F2", look: "wide",  bits: ["horns"], mouth: "smile", power: "stone" },
  avalanche:   { name: "Avalanche Yeti",  body: "#D5E2EF", look: "wide",  bits: ["horns", "crystals", "crown"], mouth: "fangs", boss: true, power: "stone" },
  // 7 Cloud Kingdom
  thunderpuff: { name: "Thunder Puff",    body: "#9AA6B8", look: "blob",  bits: ["spikes"], mouth: "frown" },
  kitesprite:  { name: "Kite Sprite",     body: "#E58FA8", look: "tall",  bits: ["wings", "tail"], mouth: "smile" },
  rainwisp:    { name: "Rain Wisp",       body: "#8FB8E5", look: "blob",  bits: [], eyes: 1, mouth: "o" },
  breezegriff: { name: "Breeze Griffin",  body: "#C9A27A", look: "round", bits: ["wings", "ears", "tail"], mouth: "fangs", power: "stone" },
  stormroc:    { name: "Storm Roc",       body: "#5C6A8C", look: "wide",  bits: ["wings", "crown", "spikes"], mouth: "fangs", boss: true, power: "heal" },
  // 8 Clockwork City
  geargremlin: { name: "Gear Gremlin",    body: "#A88B5F", look: "round", bits: ["ears", "antennae"], mouth: "fangs" },
  springbot:   { name: "Spring Bot",      body: "#9AA0A6", look: "tall",  bits: ["antennae"], eyes: 1, mouth: "smile" },
  cogcrawler:  { name: "Cog Crawler",     body: "#7A6A5C", look: "bug",   bits: ["antennae", "spikes"], eyes: 3, mouth: "o" },
  steamimp:    { name: "Steam Imp",       body: "#C96E4E", look: "tall",  bits: ["horns", "flame"], mouth: "fangs", power: "stone" },
  clockmaker:  { name: "The Great Clockmaker", body: "#6E5B7A", look: "tall", bits: ["hat", "beard", "crown"], mouth: "frown", boss: true, power: "heal" },
  // 9 Moonlit Marsh
  bogwisp:     { name: "Bog Wisp",        body: "#B9F2C8", look: "blob",  bits: ["flame"], mouth: "o" },
  nightnewt:   { name: "Night Newt",      body: "#4E6E5E", look: "wide",  bits: ["spots", "tail"], mouth: "smile" },
  mudmauler:   { name: "Mud Mauler",      body: "#6B5440", look: "wide",  bits: ["claws"], mouth: "fangs", power: "stone" },
  firefly:     { name: "Firefly Phantom", body: "#E8E6A8", look: "bug",   bits: ["wings", "antennae"], mouth: "smile" },
  murkle:      { name: "Bog Witch Murkle", body: "#6E8B4E", look: "tall", bits: ["hat", "spots"], eyes: 3, mouth: "fangs", boss: true, power: "heal" },
  // 10 Grumblegloom's Castle
  candleghost: { name: "Candle Ghost",    body: "#F2E8D5", look: "blob",  bits: ["flame"], mouth: "o" },
  gargoyle:    { name: "Gargoyle",        body: "#6E7163", look: "wide",  bits: ["wings", "horns"], mouth: "fangs", power: "stone" },
  shadowknight:{ name: "Shadow Knight",   body: "#2D2F26", look: "tall",  bits: ["helmet"], mouth: "frown" },
  quillbat:    { name: "Quill Bat",       body: "#3B3E32", look: "round", bits: ["wings", "spikes"], mouth: "fangs" },
  grumblegloom:{ name: "Grumblegloom",    body: "#8E3B5C", look: "wide",  bits: ["wings", "horns", "crown", "tail"], mouth: "fangs", boss: true, power: "heal" },
};

export const WORLDS = [
  {
    name: "Dusty Library", page: "the Page of Letters", sky: ["#F2E8D5", "#D9C9A3"], ground: "#A8875E",
    monsters: ["dustbunny", "inkblot", "papermoth", "pagemite"], boss: "ratking",
    intro: "The Great Word Book sits on its stand with ten pages torn out. Dust is stirring between the shelves. Somewhere in here, the Riddle Rat King is hiding the Page of Letters.",
    outro: "The Riddle Rat King drops the Page of Letters and scurries off. One page home! A cool breeze blows in from the woods outside.",
    levels: ["Reading Nook", "Ink Spill", "Tall Shelves", "Dusty Attic", "Map Room", "Card Catalog", "Ladder Loft", "Story Corner", "Forgotten Stacks", "The Rat King's Den"],
  },
  {
    name: "Whispering Woods", page: "the Page of Sounds", sky: ["#E3F0D8", "#9BC46A"], ground: "#5E7A3E",
    monsters: ["mosstoad", "thornsprite", "acorngrub", "spellslug"], boss: "gnomechief",
    intro: "Without the Page of Sounds the birds have gone quiet and the trees only whisper. The Grumble Gnome Chief keeps the page under his hat.",
    outro: "The Gnome Chief tips his hat and hands back the Page of Sounds. The birds sing again! A strange glow shines from the caves ahead.",
    levels: ["Mossy Path", "Toadstool Ring", "Bramble Gate", "Hollow Log", "Firefly Glade", "Owl's Bend", "Berry Patch", "Thorny Thicket", "Old Oak", "Gnome Village"],
  },
  {
    name: "Glimmer Caves", page: "the Page of Rhymes", sky: ["#D7D0E8", "#6C5B9C"], ground: "#4D4565",
    monsters: ["crystalbat", "shroomp", "echoghost", "rockling"], boss: "stonetroll",
    intro: "Deep in the caves every echo comes back wrong, because the Page of Rhymes is missing. A Stone Troll sits on it and won't budge.",
    outro: "The Stone Troll grumbles and rolls off the Page of Rhymes. The echoes rhyme again! Far off, you hear waves crashing.",
    levels: ["Cave Mouth", "Crystal Hall", "Mushroom Grotto", "Echo Tunnel", "Glow Pool", "Bat Roost", "Drippy Steps", "Gem Mine", "Deep Dark", "Troll's Throne"],
  },
  {
    name: "Stormy Sea", page: "the Page of Stories", sky: ["#D5E2EF", "#5E8FB0"], ground: "#3E6E8C",
    monsters: ["pufferpest", "crabclack", "squidscrib", "barnacle"], boss: "kraken",
    intro: "Sailors can't tell their tales anymore, because Captain Kraken Quill stole the Page of Stories. Grab a boat and spell your way across the waves.",
    outro: "Captain Kraken Quill lets go of the Page of Stories with all eight arms. The boat drifts to a hot, sandy shore.",
    levels: ["Sandy Shore", "Tide Pools", "Coral Reef", "Shipwreck", "Whirlpool", "Seaweed Forest", "Pirate Cove", "Lighthouse", "Storm Front", "The Kraken's Ship"],
  },
  {
    name: "Sandscript Desert", page: "the Page of Riddles", sky: ["#F7E7C4", "#E2B13C"], ground: "#C9A27A",
    monsters: ["scorpling", "cactuscrank", "dustdevil", "scarab"], boss: "dunesphinx",
    intro: "In the desert the riddles have gone missing, and nobody can guess anything anymore. The Dune Sphinx guards the Page of Riddles. Answer her with words!",
    outro: "The Dune Sphinx smiles at last and gives up the Page of Riddles. Snowy mountains rise beyond the dunes.",
    levels: ["Hot Sands", "Cactus Garden", "Oasis", "Mirage", "Dune Sea", "Scorpion Pass", "Buried Temple", "Sandstorm", "Hidden Tomb", "Sphinx Gate"],
  },
  {
    name: "Frostbite Peaks", page: "the Page of Poems", sky: ["#F4F7FA", "#B9C7D6"], ground: "#E8E6F2",
    monsters: ["snowpuff", "iceimp", "frostowl", "yeticub"], boss: "avalanche",
    intro: "Every poem in the land has frozen solid. The Avalanche Yeti buried the Page of Poems under a mountain of snow. Bundle up!",
    outro: "The Avalanche Yeti shakes off the snow and hands over the Page of Poems. From the top of the peak, you can see castles in the clouds.",
    levels: ["Snowy Foothills", "Ice Bridge", "Frozen Lake", "Icicle Cave", "Snowman Field", "Owl Ridge", "Blizzard Pass", "Yeti Tracks", "Summit Path", "The Frozen Peak"],
  },
  {
    name: "Cloud Kingdom", page: "the Page of Songs", sky: ["#FFFFFF", "#8FB8E5"], ground: "#D5E2EF",
    monsters: ["thunderpuff", "kitesprite", "rainwisp", "breezegriff"], boss: "stormroc",
    intro: "Up in the clouds, nobody can sing, because the Storm Roc carried off the Page of Songs. Hop from cloud to cloud and get it back.",
    outro: "The Storm Roc drops the Page of Songs, and the whole sky starts humming. Below the clouds, gears are clanking in a city.",
    levels: ["Cloud Steps", "Rainbow Bridge", "Kite Field", "Raindrop Falls", "Thunder Hill", "Windmill Isle", "Sky Garden", "Feather Nest", "Lightning Tower", "The Roc's Perch"],
  },
  {
    name: "Clockwork City", page: "the Page of Spelling", sky: ["#E8E2D1", "#A88B5F"], ground: "#6E7163",
    monsters: ["geargremlin", "springbot", "cogcrawler", "steamimp"], boss: "clockmaker",
    intro: "In Clockwork City every sign is spelled wrong, because the Great Clockmaker locked the Page of Spelling inside his biggest clock.",
    outro: "The Great Clockmaker winds down and opens the clock. The Page of Spelling is free! Night falls, and a misty marsh lies ahead.",
    levels: ["City Gates", "Gear Street", "Spring Market", "Steam Factory", "Cog Bridge", "Bell Tower", "Pipe Maze", "Robot Workshop", "Clock Square", "The Clockmaker's Tower"],
  },
  {
    name: "Moonlit Marsh", page: "the Page of Dreams", sky: ["#3E4A6E", "#2D3E3A"], ground: "#4E6E5E",
    monsters: ["bogwisp", "nightnewt", "mudmauler", "firefly"], boss: "murkle",
    intro: "Nobody in the land can dream, because Bog Witch Murkle stirred the Page of Dreams into her cauldron. Follow the fireflies through the marsh.",
    outro: "Murkle sneezes, and the Page of Dreams pops out of her cauldron. Only one page is left, and it's in Grumblegloom's castle.",
    levels: ["Misty Edge", "Lily Pads", "Firefly Path", "Sinking Bog", "Willow Hollow", "Frog Chorus", "Moon Pool", "Murky Maze", "Witch's Garden", "Murkle's Hut"],
  },
  {
    name: "Grumblegloom's Castle", page: "the Last Page", sky: ["#E3D7E3", "#5C4A6E"], ground: "#3B3E32",
    monsters: ["candleghost", "gargoyle", "shadowknight", "quillbat"], boss: "grumblegloom",
    intro: "Grumblegloom hates noise, and words are the noisiest thing of all. Climb the castle, beat its guards, and win back the Last Page.",
    outro: "Grumblegloom lets out one last grumble and flaps away. All ten pages are back in the Great Word Book, and every word in the land shines again. You did it, Word Hero!",
    levels: ["Drawbridge", "Great Hall", "Candle Stairs", "Armory", "Banquet Hall", "Gargoyle Roof", "Shadow Gallery", "Secret Library", "Tower Climb", "Grumblegloom's Lair"],
  },
];
export const LEVEL_TOTAL = WORLDS.length * LEVELS_PER_WORLD; // 100

export const worldOf = n => Math.floor((n - 1) / LEVELS_PER_WORLD);   // 0-based world
export const stepOf = n => ((n - 1) % LEVELS_PER_WORLD) + 1;          // 1–10 inside the world
export const levelName = n => WORLDS[worldOf(n)].levels[stepOf(n) - 1];

// The monsters in level n (1–100), toughest last. diff scales health and hits.
// Health is in points: a word hits for its exact score.
export function monstersForLevel(n, diff) {
  const w = worldOf(n);
  const s = stepOf(n);
  const world = WORLDS[w];
  const count = s <= 2 ? 2 : s <= 6 ? 3 : 4;
  const regularHp = 100 + 35 * w + 8 * (s - 1);
  const hitLo = 2 + Math.round(w * 0.6);
  const hitHi = 4 + w + (s >= 7 ? 1 : 0);
  const keys = [];
  if (s === LEVELS_PER_WORLD) {
    keys.push(world.monsters[n % 4], world.monsters[(n + 1) % 4], world.boss);
  } else {
    for (let i = 0; i < count; i++) keys.push(world.monsters[(s + i) % 4]);
  }
  return keys.map(k => makeMonster(k, diff, regularHp, [hitLo, hitHi]));
}

function makeMonster(key, diff, hp, hit) {
  const m = MONSTERS[key];
  const boss = !!m.boss;
  return {
    key, ...m,
    hp: Math.round((hp * (boss ? 3 : 1) * diff.monsterHp) / 10) * 10,
    hit: [Math.max(1, Math.round(hit[0] * diff.monsterHit * (boss ? 1.2 : 1))), Math.max(1, Math.round(hit[1] * diff.monsterHit * (boss ? 1.2 : 1)))],
  };
}

// Your hero gets tougher as the map goes on: 60 at the start, 186 by the last level.
export const heroHpForLevel = n => 60 + 12 * worldOf(n) + 2 * (stepOf(n) - 1);

// Endless: monsters from every world in turn, a bit tougher each time round.
const ENDLESS_KEYS = WORLDS.flatMap(w => [...w.monsters, w.boss]);
export const endlessWorld = stage => Math.min(WORLDS.length - 1, Math.floor((stage - 1) / 5));
export function endlessMonster(stage, diff) {
  const key = ENDLESS_KEYS[(stage - 1) % ENDLESS_KEYS.length];
  const round = Math.floor((stage - 1) / ENDLESS_KEYS.length);
  const w = endlessWorld(stage);
  const k = 1 + 0.4 * round;
  return makeMonster(key, diff, Math.round((100 + 35 * w) * k), [Math.round((2 + w * 0.6) * k), Math.round((4 + w) * k)]);
}
export const ENDLESS_HERO_HP = 80;

// Potions: found when monsters are beaten, kept between games (up to 5 of each).
export const POTIONS = {
  heal:   { name: "Health potion", short: "Heal",   color: "#D7261E", text: "Get back 40% of your health" },
  power:  { name: "Power potion",  short: "Power",  color: "#E2B13C", text: "Your next word hits twice as hard" },
  freeze: { name: "Freeze potion", short: "Freeze", color: "#3F8DB8", text: "The monster skips its next 2 attacks" },
};
export const POTION_KEYS = ["heal", "power", "freeze"];
export const POTION_MAX = 5;
