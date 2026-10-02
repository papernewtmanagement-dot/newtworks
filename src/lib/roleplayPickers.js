// Role play pickers (see [Roleplay:] in markdown.js), shared by the manual
// pages and the onboarding pop-ups. One card shows at a time: a random card on
// load, a random card for whatever springboard is picked, and the refresh
// button steps to the next one.

// Shows one card for the chosen springboard, picked at random. fresh=true
// avoids repeating the card already showing when there is more than one.
function nwRoleplayShow(rp, fresh) {
  const sel = rp.querySelector("select.nw-rp-select");
  const label = sel ? sel.value : null;
  const cards = Array.from(rp.querySelectorAll(".nw-rp-card"));
  const pool = cards.filter((c) => !label || c.getAttribute("data-rp-label") === label);
  if (!pool.length) return;
  const current = pool.find((c) => !c.hidden);
  const choices = fresh && current && pool.length > 1 ? pool.filter((c) => c !== current) : pool;
  const next = choices[Math.floor(Math.random() * choices.length)];
  cards.forEach((c) => { c.hidden = c !== next; });
}

// Refresh button: step to the next card for the chosen springboard, so every
// customer comes around before any repeats.
function nwRoleplayNext(rp) {
  const sel = rp.querySelector("select.nw-rp-select");
  const label = sel ? sel.value : null;
  const cards = Array.from(rp.querySelectorAll(".nw-rp-card"));
  const pool = cards.filter((c) => !label || c.getAttribute("data-rp-label") === label);
  if (pool.length < 2) return;
  const at = pool.findIndex((c) => !c.hidden);
  const next = pool[(at + 1) % pool.length];
  cards.forEach((c) => { c.hidden = c !== next; });
}

// Objection and bank pickers ([Roleplay: id | shuffle] and {{pick: Title}}):
// a random entry, and on refresh a different random entry. With a dropdown,
// the dropdown follows along so it always names what is showing.
function nwRoleplayShuffle(rp, fresh) {
  const sel = rp.querySelector("select.nw-rp-select");
  const cards = Array.from(rp.querySelectorAll(".nw-rp-card"));
  if (!cards.length) return;
  if (sel) {
    const opts = Array.from(sel.options).map((o) => o.value);
    let choices = fresh ? opts.filter((v) => v !== sel.value) : opts;
    if (!choices.length) choices = opts;
    sel.value = choices[Math.floor(Math.random() * choices.length)];
    let shown = false;
    cards.forEach((c) => {
      const hit = !shown && c.getAttribute("data-rp-label") === sel.value;
      if (hit) shown = true;
      c.hidden = !hit;
    });
    return;
  }
  const current = cards.find((c) => !c.hidden);
  const choices = fresh && current && cards.length > 1 ? cards.filter((c) => c !== current) : cards;
  const next = choices[Math.floor(Math.random() * choices.length)];
  cards.forEach((c) => { c.hidden = c !== next; });
}

// Wires every picker under root. Returns the cleanup, so a React effect can
// return it straight back.
export function wireRoleplayPickers(root) {
  if (!root) return undefined;
  root.querySelectorAll(".nw-rp").forEach((rp) => (
    rp.hasAttribute("data-rp-mode") ? nwRoleplayShuffle(rp, false) : nwRoleplayShow(rp, false)
  ));
  const onChange = (e) => {
    const sel = e.target;
    if (!sel || !sel.classList || !sel.classList.contains("nw-rp-select")) return;
    const rp = sel.closest(".nw-rp");
    if (rp) nwRoleplayShow(rp, false);
  };
  const onClick = (e) => {
    const btn = e.target?.closest?.(".nw-rp-next");
    if (!btn) return;
    e.preventDefault();
    const rp = btn.closest(".nw-rp");
    if (!rp) return;
    if (rp.hasAttribute("data-rp-mode")) nwRoleplayShuffle(rp, true);
    else nwRoleplayNext(rp);
  };
  root.addEventListener("change", onChange);
  root.addEventListener("click", onClick);
  return () => {
    root.removeEventListener("change", onChange);
    root.removeEventListener("click", onClick);
  };
}
