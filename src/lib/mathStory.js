// =========================================================================
// mathStory.js — Math Blast missions: the story and its eight worlds.
// Our own cast: you (the Space Cadet), Sprocket the robot pup, Captain Vega,
// and Grumbolt the Junk King. Each world is one mission in four parts:
// Asteroid Blast, Fuel Recycler, Cave Flight, Saucer Chase.
// =========================================================================

export const PARTS = [
  { key: "blast",   name: "Asteroid Blast", goal: 10, tip: "Blast the junk with the right answer." },
  { key: "recycle", name: "Fuel Recycler",  goal: 8,  tip: "Fill in the missing piece to make fuel." },
  { key: "cave",    name: "Cave Flight",    goal: 8,  tip: "Fly through the opening your number fits in." },
  { key: "boss",    name: "Saucer Chase",   goal: 6,  tip: "Fly through the right answer before time runs out." },
];

// Captain Vega between parts.
export const PART_LINES = [
  "Nice shooting, Cadet! Now feed all that junk into the recycler. Fill in each missing piece to turn it into fuel.",
  "The tanks are full! Grumbolt ducked into the caves. Your number has to fit between the two numbers on an opening to fly through it. Watch out for drips, they change your number!",
  "You made it out of the caves, and there's his saucer! Fly through the opening with the right answer before time runs out.",
];

// Things in the caves; answer a problem to get the tool that clears each one.
export const CAVE_BLOCKERS = [
  { what: "A bat blocks the way", icon: "🦇", tool: "flashlight", toolIcon: "🔦" },
  { what: "A sticky web blocks the way", icon: "🕸️", tool: "scissors", toolIcon: "✂️" },
  { what: "A boulder blocks the way", icon: "🪨", tool: "hammer", toolIcon: "🔨" },
  { what: "A cave alien blocks the way", icon: "👾", tool: "bug spray", toolIcon: "🧴" },
];

export const MISSION_WORLDS = [
  {
    name: "Moon Dock", sky: ["#2B3A67", "#0B0E1F"], planet: "#C9CCD6", ring: null,
    intro: "Sprocket the robot pup was fixing your ship's engine at Moon Dock when a shadow fell over the landing pad. Grumbolt the Junk King swooped down in his rusty saucer, grabbed Sprocket with a big metal claw, and dumped a mountain of junk all over the dock. Your radio crackles. It's Captain Vega. \"Cadet, clear that junk, make fuel, chase him through the caves, and catch that saucer. Bring Sprocket home!\"",
    outro: "You zoomed through the right answer and the saucer's claw popped open, but Grumbolt slammed it shut and blasted away toward the Rusty Rings. Sprocket's tail light blinked at you through the window. He's okay, and he's counting on you.",
  },
  {
    name: "Rusty Rings", sky: ["#5A3A2B", "#160D0A"], planet: "#C77B4A", ring: "#E0A070",
    intro: "The Rusty Rings are a belt of old asteroids, and Grumbolt has covered them in broken robots and bent pipes. Captain Vega spots his saucer hiding behind the biggest ring. \"He's stuck until he fixes his engine. Move fast, Cadet!\"",
    outro: "Your shot knocked a bolt loose from the saucer, and it wobbled off toward a frozen blue planet. Sprocket barked a little beep as it went. Grumbolt is getting nervous.",
  },
  {
    name: "Frost Planet Glimmer", sky: ["#3A6A8E", "#0A1626"], planet: "#BFE6FF", ring: null,
    intro: "Glimmer is so cold that the junk froze into icy towers. Grumbolt's saucer left a trail of frosty smoke into the ice caves. \"Bundle up, Cadet,\" says Captain Vega. \"Those caves get slippery.\"",
    outro: "The saucer skidded across the ice and spun away into space, heading for a moon covered in giant mushrooms. You found one of Sprocket's spare bolts on the ice. You're getting closer.",
  },
  {
    name: "Mushroom Moon Sporra", sky: ["#4A2E5E", "#140A1C"], planet: "#9A6FC4", ring: null,
    intro: "Sporra is covered in mushrooms as tall as buildings, and Grumbolt has stuffed junk under every one. Some of the mushrooms puff out purple clouds when you fly past. \"Don't sneeze, Cadet,\" Captain Vega laughs.",
    outro: "A mushroom puff sent the saucer tumbling, and you heard Sprocket yell \"Woof!\" over the radio. Grumbolt fixed his engine just in time and fled to a planet glowing bright red.",
  },
  {
    name: "Lava World Pyrox", sky: ["#6E1E10", "#1A0603"], planet: "#E5532E", ring: null,
    intro: "Pyrox is all volcanoes and rivers of lava. Grumbolt is melting his junk into a bigger, meaner saucer. \"Stay cool, Cadet,\" Captain Vega says. \"You've got this.\"",
    outro: "His new saucer was too hot to handle. It sputtered and steamed and limped off toward a city floating in the clouds. Sprocket waved his paw from the window.",
  },
  {
    name: "Cloud City Zephyra", sky: ["#6C8FD8", "#1E2A55"], planet: "#F2C6E0", ring: "#FFFFFF",
    intro: "Zephyra floats high in pink clouds, and its people are not happy about Grumbolt's junk falling on their rooftops. They've lent you a turbo boost. \"Use it well, Cadet,\" says Captain Vega.",
    outro: "With the turbo boost you nearly caught him! Grumbolt dropped a cloud of junk to slow you down and zipped toward a planet that sparkles like a jewel.",
  },
  {
    name: "Crystal Caves of Quarra", sky: ["#1E6E6A", "#06201F"], planet: "#6FE0D2", ring: null,
    intro: "Quarra's caves are full of glowing crystals, and Grumbolt is hiding his whole junk pile here. Sprocket has been leaving a trail of shiny bolts so you can find him. \"Smart pup,\" says Captain Vega.",
    outro: "The crystals lit up the saucer's escape route. Grumbolt is running home to his junk fortress. One more mission, Cadet, and Sprocket is free.",
  },
  {
    name: "Junk King's Fortress", sky: ["#3A4030", "#0E100B"], planet: "#7C8A5E", ring: "#A8B48A",
    intro: "Grumbolt's fortress is a giant pile of junk with a crown on top. Inside, Sprocket is locked in a cage made of old shopping carts. \"This is it, Cadet,\" says Captain Vega. \"Everything you've learned comes down to this.\"",
    outro: "You flew through the last right answer and the fortress fell apart like a stack of tin cans. The cage popped open and Sprocket leaped into your ship, beeping and wagging his tail! Grumbolt drifted away in a broken saucer, promising to clean up his junk. Captain Vega gives you a medal. You saved Sprocket, Space Cadet!",
  },
];

// Stars for a mission: fewer misses, more stars.
export const missionStars = misses => (misses <= 2 ? 3 : misses <= 6 ? 2 : 1);
