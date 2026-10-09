// =========================================================================
// questWorlds.js — the story, worlds, levels, monsters and treasures of
// Spelling Quest's Monsters mode. Pure data plus the functions that turn it
// into a level.
//
// The story, in two halves:
//   Worlds 1–10: the Great Word Book kept every word in the land bright, until
//   Grumblegloom, a dragon who hates noise, tore out its ten pages and woke the
//   monsters. Win each page back from the boss guarding it.
//   Worlds 11–20: beaten at his castle, Grumblegloom flees to the Far Lands with
//   the book's ten Lost Chapters. Follow him to the Silent Spire and end it.
//
// 20 worlds x 20 levels = 400 levels, numbered 1–400. Every level is five
// monsters; level 20 of each world ends with that world's boss as the fifth.
// Each world has a theme (its sky, ground and scenery) and each level a
// sub-theme: its name plus the scenery it adds (src/components/QuestScene.jsx).
// Beating a world's boss wins its treasure (equip up to three).
// =========================================================================

export const LEVELS_PER_WORLD = 20;
export const MONSTERS_PER_LEVEL = 5;

// Monster: name, body color, look (round, blob, tall, wide, bug), bits (add-ons),
// mouth, eyes (1–3), power:
//   stone  = may turn one of your letters to stone for 3 turns
//   burn   = may set one of your letters burning; use it within 3 turns or it burns you
//   poison = may poison you (a little health lost each turn for 3 turns)
//   weaken = may weaken you (your next 2 words hit half as hard)
//   heal   = mends itself every third turn (bosses)
const M = (name, body, look, bits = [], mouth = "smile", extra = {}) => ({ name, body, look, bits, mouth, ...extra });

export const MONSTERS = {
  // 1 Dusty Library
  dustbunny: M("Dust Bunny", "#C9C2B8", "round", ["ears"]),
  inkblot: M("Ink Blot", "#4A477E", "blob", [], "o", { eyes: 1, power: "weaken" }),
  papermoth: M("Paper Moth", "#D9C9A3", "bug", ["wings", "antennae"]),
  pagemite: M("Page Mite", "#A8875E", "wide", ["antennae"], "fangs", { eyes: 3 }),
  ratking: M("Riddle Rat King", "#8C7B6B", "round", ["ears", "crown", "tail"], "fangs", { boss: true, power: "heal" }),
  // 2 Whispering Woods
  mosstoad: M("Moss Toad", "#5E8C6A", "wide", ["spots"], "frown", { power: "poison" }),
  thornsprite: M("Thorn Sprite", "#9BC46A", "tall", ["wings", "spikes"]),
  acorngrub: M("Acorn Grub", "#B07A3E", "round", ["cap"], "o"),
  spellslug: M("Spell Slug", "#8DBA5E", "blob", ["antennae"], "smile", { power: "stone" }),
  gnomechief: M("Grumble Gnome Chief", "#6E8B4E", "tall", ["hat", "beard"], "frown", { boss: true, power: "heal" }),
  // 3 Glimmer Caves
  crystalbat: M("Crystal Bat", "#6C5B9C", "round", ["wings", "ears"], "fangs"),
  shroomp: M("Shroomp", "#E8D9C4", "tall", ["cap"], "smile", { power: "poison" }),
  echoghost: M("Echo Ghost", "#E8E6F2", "blob", [], "o", { power: "weaken" }),
  rockling: M("Rockling", "#8A8478", "wide", ["crystals"], "frown", { power: "stone" }),
  stonetroll: M("Stone Troll", "#7A6A8C", "wide", ["horns", "crystals"], "fangs", { boss: true, power: "stone" }),
  // 4 Stormy Sea
  pufferpest: M("Puffer Pest", "#E2B13C", "round", ["spikes", "fins"], "o", { power: "poison" }),
  crabclack: M("Crab Clacker", "#D2553E", "wide", ["claws"]),
  squidscrib: M("Squid Scribbler", "#B86FA8", "tall", ["tentacles"], "o", { power: "weaken" }),
  barnacle: M("Barnacle Blob", "#7FA6A0", "blob", ["spots"], "frown", { eyes: 3, power: "stone" }),
  kraken: M("Captain Kraken Quill", "#3E6E8C", "tall", ["tentacles", "hat"], "fangs", { boss: true, power: "heal" }),
  // 5 Sandscript Desert
  scorpling: M("Sand Scorpling", "#D9A55B", "wide", ["claws", "tail"], "fangs", { power: "poison" }),
  cactuscrank: M("Cactus Crank", "#6E9B4E", "tall", ["spikes"], "frown"),
  dustdevil: M("Dust Devil", "#C9A27A", "blob", ["horns"], "smile", { power: "burn" }),
  scarab: M("Riddle Scarab", "#2E7A6E", "bug", ["antennae"], "o", { eyes: 3, power: "stone" }),
  dunesphinx: M("Dune Sphinx", "#E2B13C", "wide", ["ears", "crown", "tail"], "smile", { boss: true, power: "heal" }),
  // 6 Frostbite Peaks
  snowpuff: M("Snow Puff", "#F4F7FA", "round", ["ears"], "o"),
  iceimp: M("Ice Imp", "#8CCFF2", "tall", ["horns", "wings"], "fangs", { power: "stone" }),
  frostowl: M("Frost Owl", "#B9C7D6", "round", ["wings", "ears"], "o", { power: "weaken" }),
  yeticub: M("Yeti Cub", "#E8E6F2", "wide", ["horns"]),
  avalanche: M("Avalanche Yeti", "#D5E2EF", "wide", ["horns", "crystals", "crown"], "fangs", { boss: true, power: "stone" }),
  // 7 Cloud Kingdom
  thunderpuff: M("Thunder Puff", "#9AA6B8", "blob", ["spikes"], "frown", { power: "burn" }),
  kitesprite: M("Kite Sprite", "#E58FA8", "tall", ["wings", "tail"]),
  rainwisp: M("Rain Wisp", "#8FB8E5", "blob", [], "o", { eyes: 1, power: "weaken" }),
  breezegriff: M("Breeze Griffin", "#C9A27A", "round", ["wings", "ears", "tail"], "fangs"),
  stormroc: M("Storm Roc", "#5C6A8C", "wide", ["wings", "crown", "spikes"], "fangs", { boss: true, power: "heal" }),
  // 8 Clockwork City
  geargremlin: M("Gear Gremlin", "#A88B5F", "round", ["ears", "antennae"], "fangs", { power: "stone" }),
  springbot: M("Spring Bot", "#9AA0A6", "tall", ["antennae"], "smile", { eyes: 1 }),
  cogcrawler: M("Cog Crawler", "#7A6A5C", "bug", ["antennae", "spikes"], "o", { eyes: 3 }),
  steamimp: M("Steam Imp", "#C96E4E", "tall", ["horns", "flame"], "fangs", { power: "burn" }),
  clockmaker: M("The Great Clockmaker", "#6E5B7A", "tall", ["hat", "beard"], "frown", { boss: true, power: "heal" }),
  // 9 Moonlit Marsh
  bogwisp: M("Bog Wisp", "#B9F2C8", "blob", ["flame"], "o", { power: "burn" }),
  nightnewt: M("Night Newt", "#4E6E5E", "wide", ["spots", "tail"]),
  mudmauler: M("Mud Mauler", "#6B5440", "wide", ["claws"], "fangs", { power: "stone" }),
  firefly: M("Firefly Phantom", "#E8E6A8", "bug", ["wings", "antennae"], "smile", { power: "poison" }),
  murkle: M("Bog Witch Murkle", "#6E8B4E", "tall", ["hat", "spots"], "fangs", { eyes: 3, boss: true, power: "heal" }),
  // 10 Grumblegloom's Castle
  candleghost: M("Candle Ghost", "#F2E8D5", "blob", ["flame"], "o", { power: "burn" }),
  gargoyle: M("Gargoyle", "#6E7163", "wide", ["wings", "horns"], "fangs", { power: "stone" }),
  shadowknight: M("Shadow Knight", "#2D2F26", "tall", ["helmet"], "frown", { power: "weaken" }),
  quillbat: M("Quill Bat", "#3B3E32", "round", ["wings", "spikes"], "fangs"),
  grumblegloom: M("Grumblegloom", "#8E3B5C", "wide", ["wings", "horns", "crown", "tail"], "fangs", { boss: true, power: "heal" }),
  // 11 Candy Canyon
  gumdrop: M("Gumdrop Goblin", "#E2557A", "round", ["ears", "stripes"]),
  licorice: M("Licorice Lurker", "#3B3E32", "tall", ["stripes"], "fangs", { power: "weaken" }),
  taffy: M("Taffy Troll", "#F2A65A", "wide", ["horns", "stripes"], "frown", { power: "stone" }),
  sprinkle: M("Sprinkle Sprite", "#F2DDDA", "bug", ["wings", "spots"]),
  bonbon: M("Queen Bonbon", "#B86FA8", "round", ["crown", "stripes"], "smile", { boss: true, power: "heal" }),
  // 12 Jungle Ruins
  vinesnap: M("Vine Snapper", "#4E8B3E", "wide", ["leaf"], "fangs", { power: "poison" }),
  monkeymess: M("Mischief Monkey", "#8C6B4E", "round", ["ears", "tail"]),
  tikitotem: M("Tiki Totem", "#A8875E", "tall", ["crown"], "frown", { power: "stone" }),
  junglefrog: M("Dart Frog", "#2E9BD6", "wide", ["spots"], "o", { power: "poison" }),
  templeguard: M("Temple Guardian", "#7A8C5E", "tall", ["helmet", "leaf"], "fangs", { boss: true, power: "stone" }),
  // 13 Volcano Isle
  lavablob: M("Lava Blob", "#E2552E", "blob", ["flame"], "o", { power: "burn" }),
  emberimp: M("Ember Imp", "#F28C3E", "tall", ["horns", "wings"], "fangs", { power: "burn" }),
  magmacrab: M("Magma Crab", "#B8483A", "wide", ["claws", "spikes"]),
  ashbat: M("Ash Bat", "#5C5E50", "round", ["wings", "ears"], "fangs", { power: "weaken" }),
  cinderjaw: M("Cinderjaw the Drake", "#D7261E", "wide", ["wings", "horns", "tail", "crown"], "fangs", { boss: true, power: "heal" }),
  // 14 Carnival of Echoes
  popcorn: M("Popcorn Ghost", "#FFF3CD", "blob", ["spots"], "o"),
  balloonbug: M("Balloon Bug", "#E2557A", "bug", ["antennae"], "smile", { power: "weaken" }),
  carousel: M("Carousel Critter", "#B86FA8", "round", ["horns", "stripes"]),
  tickettaker: M("Ticket Taker", "#5C4A6E", "tall", ["hat"], "frown", { power: "stone" }),
  ringmaster: M("Ringmaster Grin", "#D2553E", "tall", ["hat", "stripes"], "fangs", { boss: true, power: "heal" }),
  // 15 Starlight Station
  starsprite: M("Star Sprite", "#FFE680", "round", ["star", "wings"]),
  cometkid: M("Comet Kid", "#8CCFF2", "blob", ["flame"], "smile", { power: "burn" }),
  moonmite: M("Moon Mite", "#C9CCB8", "bug", ["antennae"], "o", { eyes: 3, power: "stone" }),
  zorb: M("Zorb the Visitor", "#9BC46A", "tall", ["antennae"], "o", { eyes: 1, power: "weaken" }),
  nebula: M("Nebula Nibbler", "#6C5B9C", "wide", ["star", "crown", "tentacles"], "fangs", { boss: true, power: "heal" }),
  // 16 Toybox Town
  windmouse: M("Wind-Up Mouse", "#9AA0A6", "round", ["ears", "tail"]),
  boxjack: M("Box Jumper", "#E2B13C", "tall", ["hat", "stripes"], "smile", { power: "weaken" }),
  ragpup: M("Rag Pup", "#C9A27A", "round", ["ears", "spots"], "o"),
  blockbot: M("Block Bot", "#3F8DB8", "tall", ["antennae"], "frown", { eyes: 1, power: "stone" }),
  gizmorex: M("Gizmo Rex", "#5E8C6A", "wide", ["spikes", "crown", "tail"], "fangs", { boss: true, power: "heal" }),
  // 17 Mirror Maze
  mirrorimp: M("Mirror Imp", "#D5E2EF", "tall", ["horns"], "fangs", { power: "weaken" }),
  prismbug: M("Prism Bug", "#B9E3F2", "bug", ["wings", "crystals"]),
  echotwin: M("Echo Twin", "#E8E6F2", "blob", [], "smile", { eyes: 1 }),
  glassgolem: M("Glass Golem", "#8CCFF2", "wide", ["crystals"], "frown", { power: "stone" }),
  lookingglass: M("The Looking-Glass Lord", "#B9C7D6", "tall", ["crown", "crystals"], "fangs", { boss: true, power: "heal" }),
  // 18 Giant's Garden
  snailtank: M("Snail Tank", "#B07A3E", "wide", ["antennae"], "o", { power: "stone" }),
  beetlebrute: M("Beetle Brute", "#2E7A6E", "bug", ["horns"], "fangs"),
  molemuncher: M("Mole Muncher", "#6B5440", "round", ["claws"], "o", { power: "weaken" }),
  buzzbee: M("Buzz Bee", "#E2B13C", "bug", ["wings", "stripes", "antennae"], "smile", { power: "poison" }),
  weedking: M("The Weed King", "#4E8B3E", "tall", ["leaf", "crown", "spikes"], "fangs", { boss: true, power: "heal" }),
  // 19 Dino Valley
  dinopup: M("Dino Pup", "#9BC46A", "round", ["spikes", "tail"]),
  raptorrunt: M("Raptor Runt", "#C96E4E", "tall", ["claws", "tail"], "fangs", { power: "weaken" }),
  fernstomper: M("Fern Stomper", "#5E7A3E", "wide", ["horns", "spots"], "frown", { power: "stone" }),
  pterror: M("Pterror", "#A88B5F", "round", ["wings", "horns"], "fangs"),
  rexthunder: M("Rex Thunderfoot", "#7A8C5E", "wide", ["spikes", "crown", "tail"], "fangs", { boss: true, power: "heal" }),
  // 20 The Silent Spire
  hushwraith: M("Hush Wraith", "#5C5E50", "blob", [], "frown", { eyes: 1, power: "weaken" }),
  shushhound: M("Shush Hound", "#3B3E32", "round", ["ears", "tail"], "fangs", { power: "poison" }),
  mutegolem: M("Mute Golem", "#7A7C6E", "wide", ["crystals", "helmet"], "frown", { power: "stone" }),
  gloommoth: M("Gloom Moth", "#6E5B7A", "bug", ["wings", "antennae"], "o", { power: "burn" }),
  grumbleking: M("Grumblegloom Unbound", "#5C1F3A", "wide", ["wings", "horns", "crown", "tail", "spikes"], "fangs", { boss: true, power: "heal" }),
};

// Levels: "Name:scenery,scenery" — the name and scenery are the level's sub-theme.
const L = s => s.split("|").map(x => { const [name, props = ""] = x.split(":"); return { name, props: props ? props.split(",") : [] }; });

export const WORLDS = [
  { name: "Dusty Library", page: "the Page of Letters", sky: ["#F2E8D5", "#D9C9A3"], ground: "#A8875E", base: ["shelf"],
    monsters: ["dustbunny", "inkblot", "papermoth", "pagemite"], boss: "ratking",
    intro: "The Great Word Book sits on its stand with ten pages torn out. Dust is stirring between the shelves. The Riddle Rat King is hiding the Page of Letters somewhere in here.",
    outro: "The Riddle Rat King drops the Page of Letters and scurries off. One page home! A cool breeze blows in from the woods outside.",
    levels: L("Reading Nook:lamp,books|Ink Spill:pool,books|Tall Shelves:shelf,ladder|Dusty Attic:window,books|Map Room:banner,books|Card Catalog:block,lamp|Ladder Loft:ladder,shelf|Story Corner:lamp,flowers|Quiet Room:window,lamp|Bookbinder's Desk:books,lantern|Poetry Aisle:books,flowers|Globe Gallery:planet,shelf|Paper Pile:books,books|Candle Study:lantern,books|Rare Books Vault:column,books|Secret Passage:torch,shelf|Index Hall:column,banner|Moonlit Window:window,books|Forgotten Stacks:shelf,ladder|The Rat King's Den:banner,torch") },
  { name: "Whispering Woods", page: "the Page of Sounds", sky: ["#E3F0D8", "#9BC46A"], ground: "#5E7A3E", base: ["tree"],
    monsters: ["mosstoad", "thornsprite", "acorngrub", "spellslug"], boss: "gnomechief",
    intro: "Without the Page of Sounds the birds have gone quiet and the trees only whisper. The Grumble Gnome Chief keeps the page under his hat.",
    outro: "The Gnome Chief tips his hat and hands back the Page of Sounds. The birds sing again! A strange glow shines from the caves ahead.",
    levels: L("Mossy Path:bush,fence|Toadstool Ring:mushroom,mushroom|Bramble Gate:bush,fence|Hollow Log:rock,mushroom|Firefly Glade:lantern,flowers|Owl's Bend:tree,moon|Berry Patch:bush,flowers|Babbling Brook:pool,rock|Fern Gully:fern,fern|Woodcutter's Hut:house,fence|Sunny Clearing:flowers,flowers|Old Bridge:bridge,pool|Squirrel Hollow:tree,leaf|Thorny Thicket:bush,bush|Wishing Well:pool,rock|Lantern Trail:lantern,lantern|Mushroom Market:mushroom,tent|Deep Woods:tree,fern|Old Oak:tree,leaf|Gnome Village:house,mushroom") },
  { name: "Glimmer Caves", page: "the Page of Rhymes", sky: ["#5C4A6E", "#2D2F26"], ground: "#4D4565", base: ["stalactite"],
    monsters: ["crystalbat", "shroomp", "echoghost", "rockling"], boss: "stonetroll",
    intro: "Deep in the caves every echo comes back wrong, because the Page of Rhymes is missing. A Stone Troll sits on it and won't budge.",
    outro: "The Stone Troll grumbles and rolls off the Page of Rhymes. The echoes rhyme again! Far off, you hear waves crashing.",
    levels: L("Cave Mouth:rock,torch|Crystal Hall:crystal,crystal|Mushroom Grotto:mushroom,crystal|Echo Tunnel:rock,rock|Glow Pool:pool,crystal|Bat Roost:stalactite,rock|Drippy Steps:pool,rock|Gem Mine:crystal,ladder|Minecart Track:fence,lantern|Lost Lantern:lantern,rock|Underground River:pool,bridge|Crystal Garden:crystal,flowers|Whisper Chamber:column,crystal|Fossil Wall:bones,rock|Rope Bridge:bridge,torch|Geode Room:crystal,crystal|Old Mine Shaft:ladder,lantern|Deep Dark:rock,crystal|Lava Glow:lava,rock|Troll's Throne:crystal,banner") },
  { name: "Stormy Sea", page: "the Page of Stories", sky: ["#D5E2EF", "#5E8FB0"], ground: "#3E6E8C", base: ["wave"],
    monsters: ["pufferpest", "crabclack", "squidscrib", "barnacle"], boss: "kraken",
    intro: "Sailors can't tell their tales anymore, because Captain Kraken Quill stole the Page of Stories. Grab a boat and spell your way across the waves.",
    outro: "Captain Kraken Quill lets go of the Page of Stories with all eight arms. The boat drifts to a hot, sandy shore.",
    levels: L("Sandy Shore:palm,rock|Tide Pools:pool,rock|Coral Reef:crystal,wave|Shipwreck:ship,rock|Whirlpool:wave,wave|Seaweed Forest:fern,wave|Pirate Cove:ship,palm|Lighthouse:tower,rock|Treasure Island:palm,block|Message Bottle:pool,palm|Dolphin Bay:wave,cloud|Sea Cave:rock,stalactite|Fog Bank:cloud,cloud|Sunken Bell:tower,wave|Harbor Docks:ship,fence|Seagull Rock:rock,cloud|Storm Clouds:cloud,cloud|Giant Wave:wave,wave|Storm Front:cloud,ship|The Kraken's Ship:ship,banner") },
  { name: "Sandscript Desert", page: "the Page of Riddles", sky: ["#F7E7C4", "#E2B13C"], ground: "#C9A27A", base: ["dune"],
    monsters: ["scorpling", "cactuscrank", "dustdevil", "scarab"], boss: "dunesphinx",
    intro: "In the desert the riddles have gone missing, and nobody can guess anything anymore. The Dune Sphinx guards the Page of Riddles. Answer her with words!",
    outro: "The Dune Sphinx smiles at last and gives up the Page of Riddles. Snowy mountains rise beyond the dunes.",
    levels: L("Hot Sands:cactus,dune|Cactus Garden:cactus,cactus|Oasis:palm,pool|Mirage:pool,dune|Dune Sea:dune,dune|Scorpion Pass:rock,cactus|Camel Market:tent,palm|Buried Temple:column,pyramid|Sun Dial:column,rock|Sandstorm:dune,cloud|Pyramid Steps:pyramid,pyramid|Painted Canyon:rock,rock|Snake Rock:rock,cactus|Starry Camp:tent,moon|Hidden Well:pool,rock|Golden Gate:column,banner|Lost Caravan:tent,dune|Tomb Hall:torch,column|Hidden Tomb:pyramid,torch|Sphinx Gate:pyramid,column") },
  { name: "Frostbite Peaks", page: "the Page of Poems", sky: ["#F4F7FA", "#B9C7D6"], ground: "#E8E6F2", base: ["mountain"],
    monsters: ["snowpuff", "iceimp", "frostowl", "yeticub"], boss: "avalanche",
    intro: "Every poem in the land has frozen solid. The Avalanche Yeti buried the Page of Poems under a mountain of snow. Bundle up!",
    outro: "The Avalanche Yeti shakes off the snow and hands over the Page of Poems. From the peak, you can see castles in the clouds.",
    levels: L("Snowy Foothills:snow,tree|Ice Bridge:bridge,snow|Frozen Lake:pool,snow|Icicle Cave:stalactite,crystal|Snowman Field:snow,snow|Owl Ridge:tree,snow|Igloo Camp:igloo,snow|Sled Hill:snow,fence|Pine Forest:tree,tree|Hot Spring:pool,rock|Ice Palace Gate:castle,crystal|Frozen Waterfall:crystal,rock|Ski Lodge:house,snow|Penguin Point:igloo,rock|Blizzard Pass:snow,cloud|Northern Lights:snow,moon|Yeti Tracks:snow,rock|Crystal Glacier:crystal,crystal|Summit Path:mountain,banner|The Frozen Peak:mountain,crystal") },
  { name: "Cloud Kingdom", page: "the Page of Songs", sky: ["#FFFFFF", "#8FB8E5"], ground: "#D5E2EF", base: ["cloud"],
    monsters: ["thunderpuff", "kitesprite", "rainwisp", "breezegriff"], boss: "stormroc",
    intro: "Up in the clouds, nobody can sing, because the Storm Roc carried off the Page of Songs. Hop from cloud to cloud and get it back.",
    outro: "The Storm Roc drops the Page of Songs, and the whole sky starts humming. Below the clouds, gears clank in a city.",
    levels: L("Cloud Steps:cloud,cloud|Rainbow Bridge:rainbow,cloud|Kite Field:banner,cloud|Raindrop Falls:pool,cloud|Thunder Hill:cloud,tower|Windmill Isle:tower,cloud|Sky Garden:flowers,cloud|Feather Nest:tree,cloud|Balloon Port:tent,cloud|Sunbeam Plaza:column,rainbow|Cloud Castle:castle,cloud|Starlight Deck:cloud,moon|Hummingbird Hall:flowers,column|Mist Maze:cloud,cloud|Weather Vane:tower,banner|Bubble Bay:pool,rainbow|Sky Harbor:ship,cloud|Thundercap:cloud,mountain|Lightning Tower:tower,tower|The Roc's Perch:tree,tower") },
  { name: "Clockwork City", page: "the Page of Spelling", sky: ["#E8E2D1", "#A88B5F"], ground: "#6E7163", base: ["gear"],
    monsters: ["geargremlin", "springbot", "cogcrawler", "steamimp"], boss: "clockmaker",
    intro: "In Clockwork City every sign is spelled wrong, because the Great Clockmaker locked the Page of Spelling inside his biggest clock.",
    outro: "The Great Clockmaker winds down and opens the clock. The Page of Spelling is free! Night falls, and a misty marsh lies ahead.",
    levels: L("City Gates:castle,gear|Gear Street:gear,house|Spring Market:tent,gear|Steam Factory:pipe,pipe|Cog Bridge:bridge,gear|Bell Tower:tower,gear|Pipe Maze:pipe,pipe|Robot Workshop:block,gear|Lamp Lane:lantern,house|Train Station:fence,pipe|Inventor's Attic:window,gear|Copper Canal:pool,pipe|Rooftop Run:house,house|Tick-Tock Park:tree,tower|Spark Lab:pipe,lantern|Brass Library:shelf,gear|Smokestack Row:pipe,house|Gear Garden:gear,flowers|Clock Square:tower,lantern|The Clockmaker's Tower:tower,gear") },
  { name: "Moonlit Marsh", page: "the Page of Dreams", sky: ["#3E4A6E", "#2D3E3A"], ground: "#4E6E5E", base: ["reed"],
    monsters: ["bogwisp", "nightnewt", "mudmauler", "firefly"], boss: "murkle",
    intro: "Nobody in the land can dream, because Bog Witch Murkle stirred the Page of Dreams into her cauldron. Follow the fireflies through the marsh.",
    outro: "Murkle sneezes, and the Page of Dreams pops out of her cauldron. Only one page is left, and it's in Grumblegloom's castle.",
    levels: L("Misty Edge:reed,cloud|Lily Pads:lily,pool|Firefly Path:lantern,reed|Sinking Bog:pool,reed|Willow Hollow:tree,reed|Frog Chorus:lily,lily|Moon Pool:pool,moon|Boardwalk:bridge,reed|Cattail Corner:reed,reed|Glowworm Glen:lantern,mushroom|Heron Roost:tree,pool|Old Ferry:ship,reed|Foggy Flats:cloud,reed|Mushroom Isle:mushroom,pool|Witch Lights:lantern,lantern|Sleepy Hollow:tree,moon|Murky Maze:reed,bush|Sunken Stones:rock,pool|Witch's Garden:flowers,mushroom|Murkle's Hut:house,lantern") },
  { name: "Grumblegloom's Castle", page: "the Last Page", sky: ["#E3D7E3", "#5C4A6E"], ground: "#3B3E32", base: ["castle"],
    monsters: ["candleghost", "gargoyle", "shadowknight", "quillbat"], boss: "grumblegloom",
    intro: "Grumblegloom hates noise, and words are the noisiest thing of all. Climb his castle, beat his guards, and win back the Last Page.",
    outro: "All ten pages are back in the Great Word Book! But Grumblegloom escapes on the wind, carrying the book's ten Lost Chapters to the Far Lands. The quest isn't over.",
    levels: L("Drawbridge:bridge,castle|Great Hall:banner,column|Candle Stairs:torch,torch|Armory:banner,block|Banquet Hall:lantern,banner|Gargoyle Roof:tower,castle|Shadow Gallery:column,torch|Secret Library:shelf,books|Throne Room:banner,column|Dungeon Door:torch,rock|Moat Bridge:bridge,pool|Spiral Stair:tower,torch|Knight's Hall:banner,banner|Chapel Bells:tower,column|Portrait Hall:window,banner|Treasure Room:block,banner|Battlements:castle,banner|Tower Climb:tower,tower|Dragon's Roost:tower,moon|Grumblegloom's Lair:torch,banner") },
  { name: "Candy Canyon", page: "the Chapter of Sweet Words", sky: ["#FDE2EC", "#F2A6C0"], ground: "#E58FA8", base: ["candy"],
    monsters: ["gumdrop", "licorice", "taffy", "sprinkle"], boss: "bonbon",
    intro: "The Far Lands begin with a canyon made of candy. Queen Bonbon took the Chapter of Sweet Words, so nobody here can say anything kind. Time to fix that.",
    outro: "Queen Bonbon gives back the Chapter of Sweet Words and says thank you, sweetly. A jungle steams on the other side of the canyon.",
    levels: L("Gumdrop Gate:candy,lollipop|Lollipop Lane:lollipop,lollipop|Taffy Twist:candy,candy|Chocolate River:pool,candy|Sprinkle Hill:candy,flowers|Cookie Cottage:house,candy|Peppermint Pass:candy,rock|Cotton Candy Clouds:cloud,cloud|Jellybean Field:block,candy|Caramel Falls:pool,rock|Fudge Bridge:bridge,candy|Marshmallow Meadow:cloud,flowers|Candy Factory:pipe,candy|Gingerbread Row:house,house|Licorice Woods:tree,candy|Soda Springs:pool,lollipop|Rock Candy Cave:crystal,stalactite|Sugar Plum Grove:tree,lollipop|Sweet Shop:tent,candy|Queen Bonbon's Palace:castle,lollipop") },
  { name: "Jungle Ruins", page: "the Chapter of Questions", sky: ["#DDEFD0", "#6E9B4E"], ground: "#4E6E3E", base: ["vine"],
    monsters: ["vinesnap", "monkeymess", "tikitotem", "junglefrog"], boss: "templeguard",
    intro: "Deep in the jungle, nobody can ask a question, because the Temple Guardian locked the Chapter of Questions inside an old ruin. Swing in!",
    outro: "The Temple Guardian bows and opens the ruin. The Chapter of Questions is yours! Smoke rises from an island volcano offshore.",
    levels: L("Jungle Edge:palm,vine|Vine Swing:vine,tree|Parrot Perch:tree,flowers|Monkey Bridge:bridge,vine|Waterfall Pool:pool,rock|Tiki Steps:column,palm|Banana Grove:palm,palm|Mossy Statue:column,fern|Frog Pond:lily,pool|Hidden Temple:pyramid,vine|Snake Rock:rock,vine|Treetop Village:house,tree|Orchid Garden:flowers,fern|Mud Slide:rock,pool|Totem Circle:column,column|Jaguar Trail:fern,tree|Sunken Plaza:column,pool|Rope Ladder:ladder,vine|Golden Idol Hall:torch,block|Temple Heart:pyramid,torch") },
  { name: "Volcano Isle", page: "the Chapter of Brave Words", sky: ["#F7C9A0", "#B8483A"], ground: "#4D3B32", base: ["volcano"],
    monsters: ["lavablob", "emberimp", "magmacrab", "ashbat"], boss: "cinderjaw",
    intro: "On Volcano Isle, everyone is too scared to speak up. Cinderjaw the Drake guards the Chapter of Brave Words at the top of the volcano.",
    outro: "Cinderjaw cools off and coughs up the Chapter of Brave Words. Across the bay, carnival music drifts in on the wind.",
    levels: L("Black Sand Beach:wave,rock|Smoky Trail:rock,cloud|Lava River:lava,bridge|Ember Field:lava,rock|Obsidian Cave:crystal,stalactite|Hot Spring:pool,rock|Ash Forest:tree,cloud|Steam Vents:pipe,cloud|Fire Bridge:bridge,lava|Crater Rim:volcano,rock|Magma Pool:lava,lava|Charred Ruins:column,torch|Basalt Columns:column,column|Sulfur Springs:pool,crystal|Fireplume:volcano,lava|Dragon Bones:bones,rock|Glow Tunnel:lava,stalactite|Cinder Cone:volcano,cloud|Lava Falls:lava,rock|Cinderjaw's Crater:volcano,banner") },
  { name: "Carnival of Echoes", page: "the Chapter of Jokes", sky: ["#FFF3CD", "#E2557A"], ground: "#8E3B5C", base: ["tent"],
    monsters: ["popcorn", "balloonbug", "carousel", "tickettaker"], boss: "ringmaster",
    intro: "The carnival has lost its laughs, because Ringmaster Grin locked up the Chapter of Jokes. Every ride repeats the same tired joke. Win the laughs back!",
    outro: "Ringmaster Grin finally laughs and hands over the Chapter of Jokes. A rocket on the fairground points straight at the stars.",
    levels: L("Ticket Booth:tent,banner|Ferris Wheel:wheel,tent|Carousel:wheel,lantern|Popcorn Stand:tent,block|Balloon Alley:banner,lollipop|Funhouse:house,mirror|Bumper Cars:block,fence|Ring Toss:block,tent|Fortune Tent:tent,lantern|Juggler's Stage:banner,tent|Hall of Echoes:mirror,column|Big Top:tent,tent|Cotton Candy Cart:candy,tent|Roller Coaster:wheel,bridge|Prize Booth:block,banner|Lantern Midway:lantern,lantern|Strongman Bell:tower,tent|Circus Train:fence,banner|Night Parade:lantern,moon|The Ringmaster's Ring:tent,banner") },
  { name: "Starlight Station", page: "the Chapter of Wonders", sky: ["#1E2340", "#3E2E5C"], ground: "#5C5E70", base: ["planet"],
    monsters: ["starsprite", "cometkid", "moonmite", "zorb"], boss: "nebula",
    intro: "Up among the stars, nobody can wonder about anything, because the Nebula Nibbler gobbled the Chapter of Wonders. Blast off!",
    outro: "The Nebula Nibbler burps up the Chapter of Wonders. Your rocket lands in a town where all the toys are awake.",
    levels: L("Launch Pad:rocket,tower|Moon Base:house,planet|Crater Field:rock,rock|Comet Tail:rocket,cloud|Asteroid Belt:rock,planet|Space Garden:flowers,planet|Satellite Dish:tower,planet|Ring Planet:planet,planet|Star Nursery:crystal,cloud|Alien Market:tent,rocket|Zero-G Hall:block,column|Meteor Shower:rock,rock|Solar Sails:ship,planet|Moon Rover:block,rock|Galaxy Bridge:bridge,planet|Cosmic Cave:crystal,stalactite|Robot Docks:pipe,rocket|Black Hole Edge:planet,cloud|Starlight Tower:tower,rocket|The Nebula Core:planet,crystal") },
  { name: "Toybox Town", page: "the Chapter of Make-Believe", sky: ["#E3F6FF", "#8CCFF2"], ground: "#E2B13C", base: ["block"],
    monsters: ["windmouse", "boxjack", "ragpup", "blockbot"], boss: "gizmorex",
    intro: "In Toybox Town, nobody can pretend anymore, because Gizmo Rex stomped off with the Chapter of Make-Believe. Play your way through!",
    outro: "Gizmo Rex winds down and lets go of the Chapter of Make-Believe. Past the toy shelf stands a maze made of mirrors.",
    levels: L("Toy Shop Door:house,block|Block Tower:block,tower|Train Set:fence,block|Dollhouse:house,flowers|Marble Run:bridge,block|Puzzle Plaza:block,block|Kite Corner:banner,cloud|Spinning Tops:wheel,block|Paint Pots:pool,flowers|Teddy Bear Picnic:tree,tent|Robot Row:block,gear|Rocking Horse Ranch:fence,tent|Crayon Castle:castle,banner|Sticker Street:house,lollipop|Balloon Dock:banner,ship|Music Box:tower,lantern|Toy Soldier Fort:castle,fence|Bubble Bath Bay:pool,cloud|Bedtime Shelf:shelf,moon|Gizmo Rex's Toybox:block,banner") },
  { name: "Mirror Maze", page: "the Chapter of Opposites", sky: ["#EEF3F8", "#B9C7D6"], ground: "#8A8C9C", base: ["mirror"],
    monsters: ["mirrorimp", "prismbug", "echotwin", "glassgolem"], boss: "lookingglass",
    intro: "In the Mirror Maze, everything is backwards: up is down and hot is cold. The Looking-Glass Lord has the Chapter of Opposites. Find your way through!",
    outro: "The Looking-Glass Lord cracks a smile and gives back the Chapter of Opposites. Through the last mirror, you see a garden for giants.",
    levels: L("Front Door:mirror,column|Shiny Hall:mirror,mirror|Backwards Room:mirror,block|Prism Path:crystal,mirror|Echo Corner:mirror,column|Glass Stairs:ladder,mirror|Kaleidoscope:crystal,crystal|Upside-Down Garden:flowers,mirror|Silver Pool:pool,mirror|Funny Faces:mirror,lantern|Shard Bridge:bridge,crystal|Rainbow Room:rainbow,mirror|Twin Tower:tower,tower|Glass Forest:tree,crystal|Light Beam:lantern,mirror|Crystal Lake:pool,crystal|Fog Mirror:cloud,mirror|Lost Reflections:mirror,column|Hall of Kings:banner,mirror|The Looking-Glass Throne:mirror,crystal") },
  { name: "Giant's Garden", page: "the Chapter of Big Ideas", sky: ["#E3F0D8", "#8FB8E5"], ground: "#6E9B4E", base: ["leaf"],
    monsters: ["snailtank", "beetlebrute", "molemuncher", "buzzbee"], boss: "weedking",
    intro: "You're tiny in a giant's garden, where every bug is as big as a bus. The Weed King has the Chapter of Big Ideas. Think big!",
    outro: "The Weed King wilts and hands over the Chapter of Big Ideas. Over the garden wall, real dinosaurs are roaming a valley.",
    levels: L("Garden Gate:fence,flowers|Giant Daisy:flowers,flowers|Dewdrop Pond:pool,leaf|Snail Trail:leaf,rock|Beetle Bridge:bridge,leaf|Tulip Towers:flowers,tower|Mole Hills:rock,rock|Bee Hive:house,flowers|Watering Can:pipe,pool|Pumpkin Patch:bush,leaf|Sunflower Forest:flowers,tree|Spider Web:fence,leaf|Vegetable Rows:fence,bush|Seed Shed:house,fence|Clover Field:leaf,flowers|Puddle Lake:pool,lily|Rose Thorns:bush,flowers|Compost Hill:rock,mushroom|Greenhouse:window,flowers|The Weed King's Bed:leaf,banner") },
  { name: "Dino Valley", page: "the Chapter of Long Ago", sky: ["#F7E7C4", "#C9A27A"], ground: "#7A6A4E", base: ["fern"],
    monsters: ["dinopup", "raptorrunt", "fernstomper", "pterror"], boss: "rexthunder",
    intro: "Dino Valley has forgotten its own history, because Rex Thunderfoot stomped on the Chapter of Long Ago. Watch your step!",
    outro: "Rex Thunderfoot lifts his foot, and the Chapter of Long Ago is safe. Only one chapter is left, at the top of the Silent Spire.",
    levels: L("Valley Gate:fern,rock|Fern Forest:fern,fern|Nest Hill:rock,tree|Tar Pits:pool,rock|Bone Yard:bones,bones|Egg Clutch:rock,fern|Volcano View:volcano,fern|Dino Crossing:fence,fern|Swamp Lake:pool,reed|Pterror Cliffs:rock,mountain|Fossil Dig:bones,ladder|Herd Meadow:flowers,fern|Raptor Ridge:rock,tree|Giant Footprints:rock,pool|Amber Cave:crystal,stalactite|Cave Paintings:rock,torch|Long Neck Lake:pool,tree|Thunder Plains:cloud,fern|Stomping Grounds:rock,rock|Rex's Roar Rock:volcano,bones") },
  { name: "The Silent Spire", page: "the Last Chapter", sky: ["#3B3E4E", "#1E1F26"], ground: "#2D2F26", base: ["spire"],
    monsters: ["hushwraith", "shushhound", "mutegolem", "gloommoth"], boss: "grumbleking",
    intro: "Grumblegloom's tower rises over the Far Lands, so quiet you can hear your own heartbeat. Climb the Silent Spire and win back the Last Chapter for good.",
    outro: "Grumblegloom Unbound lets out one last tiny grumble, then laughs for the first time in a thousand years. Every word, page and chapter is home. The land will never be quiet again. You are the greatest Word Hero of all!",
    levels: L("Foot of the Spire:spire,rock|Hush Gate:castle,torch|Whisper Stairs:ladder,torch|Silent Library:shelf,books|Echo Pit:rock,stalactite|Gloom Garden:flowers,moon|Shadow Bridge:bridge,torch|Muffled Hall:banner,column|Moth Loft:lantern,window|Quiet Clocks:gear,tower|Hollow Bells:tower,tower|Dim Lanterns:lantern,lantern|Frozen Voices:crystal,snow|Tongue-Tied Maze:mirror,column|Storm Balcony:cloud,banner|Grumble Vault:block,torch|Lost Words Room:books,crystal|Last Staircase:ladder,tower|The Silent Throne:banner,torch|The Spire's Peak:spire,moon") },
];
export const LEVEL_TOTAL = WORLDS.length * LEVELS_PER_WORLD; // 400

export const worldOf = n => Math.floor((n - 1) / LEVELS_PER_WORLD);   // 0-based world
export const stepOf = n => ((n - 1) % LEVELS_PER_WORLD) + 1;          // 1–20 inside the world
export const levelInfo = n => WORLDS[worldOf(n)].levels[stepOf(n) - 1];
export const levelName = n => levelInfo(n).name;

// The five monsters in level n (1–400), toughest last. diff scales health and hits.
// Health is in points: a word hits for its exact score.
export function monstersForLevel(n, diff) {
  const w = worldOf(n);
  const s = stepOf(n);
  const world = WORLDS[w];
  const hp = 60 + 18 * w + 3 * (s - 1);
  const hit = [2 + Math.round(w * 0.3), 4 + Math.round(w * 0.5) + (s >= 14 ? 1 : 0)];
  const keys = [];
  for (let i = 0; i < MONSTERS_PER_LEVEL; i++) keys.push(world.monsters[(s + i) % 4]);
  if (s === LEVELS_PER_WORLD) keys[MONSTERS_PER_LEVEL - 1] = world.boss;
  // The last monster of every level is a little tougher than the rest.
  return keys.map((k, i) => makeMonster(k, diff, Math.round(hp * (i === MONSTERS_PER_LEVEL - 1 ? 1.3 : 1)), hit));
}

function makeMonster(key, diff, hp, hit) {
  const m = MONSTERS[key];
  const boss = !!m.boss;
  return {
    key, ...m,
    hp: Math.max(20, Math.round((hp * (boss ? 2.4 : 1) * diff.monsterHp) / 10) * 10),
    hit: [Math.max(1, Math.round(hit[0] * diff.monsterHit * (boss ? 1.2 : 1))), Math.max(1, Math.round(hit[1] * diff.monsterHit * (boss ? 1.2 : 1)))],
  };
}

// Your hero gets tougher as the map goes on: 60 at the start, 231 by the last level.
export const heroHpForLevel = n => 60 + 8 * worldOf(n) + (stepOf(n) - 1);

// Endless: monsters from every world in turn, a bit tougher each time round.
const ENDLESS_KEYS = WORLDS.flatMap(w => [...w.monsters, w.boss]);
export const endlessWorld = stage => Math.min(WORLDS.length - 1, Math.floor((stage - 1) / 5));
export function endlessMonster(stage, diff) {
  const key = ENDLESS_KEYS[(stage - 1) % ENDLESS_KEYS.length];
  const round = Math.floor((stage - 1) / ENDLESS_KEYS.length);
  const w = endlessWorld(stage);
  const k = 1 + 0.4 * round;
  return makeMonster(key, diff, Math.round((60 + 18 * w) * k), [Math.round((2 + w * 0.3) * k), Math.round((4 + w * 0.5) * k)]);
}
export const ENDLESS_HERO_HP = 80;

// Stars for a won level: how much health you finished with.
export const starsFor = (hp, hpMax) => (hp >= hpMax * 0.6 ? 3 : hp >= hpMax * 0.3 ? 2 : 1);

// Potions: found when monsters are beaten, kept between games (up to 5 of each).
export const POTIONS = {
  heal:   { name: "Health potion", short: "Heal",   color: "#D7261E", text: "Get back 40% of your health" },
  power:  { name: "Power potion",  short: "Power",  color: "#E2B13C", text: "Your next word hits twice as hard" },
  freeze: { name: "Freeze potion", short: "Freeze", color: "#3F8DB8", text: "The monster skips its next 2 attacks" },
  cure:   { name: "Cure potion",   short: "Cure",   color: "#8E5CB8", text: "Ends poison and weakness and frees stone and burning letters" },
};
export const POTION_KEYS = ["heal", "power", "freeze", "cure"];
export const POTION_MAX = 5;

// Treasures: each world's boss gives one. Equip up to three; they work in every fight.
//   letters  +25% damage when the word uses any of these letters
//   long     +30% damage for words of 6 or more letters
//   regen    get back this much health after each of your words
//   finder   monsters drop potions more often
//   shield   every monster hit does 1 less
//   sturdy   letters can't be turned to stone or set burning
//   antidote poison and weakness can't touch you
//   gems     5-letter gems come from 4-letter words too
//   rally    start every level with a Power potion's effect
//   mend     get back twice as much health between monsters
export const TREASURES = [
  { name: "Silver Bookmark",   color: "#B9C7D6", effect: "letters", letters: "BKP", text: "+25% damage for words with B, K or P" },
  { name: "Acorn Locket",      color: "#B07A3E", effect: "regen", amount: 2, text: "Get back 2 health after each word" },
  { name: "Echo Crystal",      color: "#8E5CB8", effect: "long", text: "+30% damage for words of 6+ letters" },
  { name: "Captain's Compass", color: "#3E6E8C", effect: "finder", text: "Monsters drop potions more often" },
  { name: "Sphinx Scarab",     color: "#2E7A6E", effect: "antidote", text: "Poison and weakness can't touch you" },
  { name: "Yeti Mittens",      color: "#E8E6F2", effect: "shield", text: "Every monster hit does 1 less" },
  { name: "Song Feather",      color: "#E58FA8", effect: "mend", text: "Get back twice as much health between monsters" },
  { name: "Golden Gear",       color: "#E2B13C", effect: "sturdy", text: "Letters can't turn to stone or burn" },
  { name: "Dream Lantern",     color: "#B9F2C8", effect: "gems", text: "4-letter words can make gems too" },
  { name: "Dragon Scale",      color: "#8E3B5C", effect: "rally", text: "Start every level with a power boost" },
  { name: "Candy Crown",       color: "#E2557A", effect: "letters", letters: "CDGM", text: "+25% damage for words with C, D, G or M" },
  { name: "Jungle Idol",       color: "#7A8C5E", effect: "regen", amount: 3, text: "Get back 3 health after each word" },
  { name: "Ember Heart",       color: "#D7261E", effect: "long", text: "+30% damage for words of 6+ letters" },
  { name: "Lucky Ticket",      color: "#FFE680", effect: "finder", text: "Monsters drop potions more often" },
  { name: "Star Map",          color: "#6C5B9C", effect: "letters", letters: "FHWY", text: "+25% damage for words with F, H, W or Y" },
  { name: "Wind-Up Key",       color: "#9AA0A6", effect: "shield", text: "Every monster hit does 1 less" },
  { name: "Prism Shard",       color: "#8CCFF2", effect: "letters", letters: "JQXZV", text: "+25% damage for words with J, Qu, X, Z or V" },
  { name: "Giant's Seed",      color: "#4E8B3E", effect: "mend", text: "Get back twice as much health between monsters" },
  { name: "Amber Fossil",      color: "#E2A33C", effect: "regen", amount: 4, text: "Get back 4 health after each word" },
  { name: "Word Hero's Crown", color: "#E2B13C", effect: "long", text: "+30% damage for words of 6+ letters" },
];
export const EQUIP_MAX = 3;

// Treasures power up the more they're worn: every level won while wearing one
// counts as a win for it. Level 2 at 10 wins, level 3 at 25.
export const TREASURE_LEVEL_AT = [0, 10, 25];
export const treasureLevel = xp => (xp >= TREASURE_LEVEL_AT[2] ? 3 : xp >= TREASURE_LEVEL_AT[1] ? 2 : 1);
// What each effect is worth at levels 1, 2 and 3. The on/off treasures (sturdy,
// antidote, gems, rally) add a little damage instead as they level up.
const POWER = { letters: [25, 35, 50], long: [30, 40, 60], regen: [1, 1.5, 2], finder: [25, 35, 50], shield: [1, 2, 3], mend: [2, 2.5, 3], extra: [0, 10, 20] };
export function treasurePower(t, lv) {
  const k = Math.max(1, Math.min(3, lv)) - 1;
  const extra = POWER.extra[k];
  switch (t.effect) {
    case "letters": return { value: POWER.letters[k], text: t.text.replace("+25%", `+${POWER.letters[k]}%`) };
    case "long": return { value: POWER.long[k], text: t.text.replace("+30%", `+${POWER.long[k]}%`) };
    case "regen": { const n = Math.round(t.amount * POWER.regen[k]); return { value: n, text: `Get back ${n} health after each word` }; }
    case "finder": return { value: POWER.finder[k], text: `Monsters drop potions more often (+${POWER.finder[k]}% chance)` };
    case "shield": return { value: POWER.shield[k], text: `Every monster hit does ${POWER.shield[k]} less` };
    case "mend": return { value: POWER.mend[k], text: `Get back ${POWER.mend[k]} times as much health between monsters` };
    default: return { value: 1, extra, text: `${t.text}${extra ? ` · +${extra}% damage` : ""}` };
  }
}
// Treasure i is owned once world i's boss (level 20, 40, 60…) has been beaten.
// xp: { "<i>": levels won while wearing it }.
export const treasuresOwned = (unlocked, xp = {}) => TREASURES.map((t, i) => {
  const wins = Math.max(0, Number(xp[i]) || 0);
  const lv = treasureLevel(wins);
  return { ...t, ...treasurePower(t, lv), i, owned: unlocked > (i + 1) * LEVELS_PER_WORLD, xp: wins, lv, next: lv < 3 ? TREASURE_LEVEL_AT[lv] : null };
});

// The two halves of the story, told before worlds 1 and 11.
export const STORY_PARTS = [
  "The Ten Pages. The Great Word Book kept every word in the land bright, until Grumblegloom, a dragon who hates noise, tore out its ten pages and woke the monsters. Win the pages back!",
  "The Lost Chapters. Grumblegloom escaped to the Far Lands with the book's ten Lost Chapters. Follow him all the way to the Silent Spire.",
];
