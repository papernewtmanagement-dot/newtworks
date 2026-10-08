// src/lib/choices.js
//
// Clicks for [Choose:] blocks (see markdown.js). Peter 2026-10-07: the kickoff
// role play pop-up — team member or customer, inbound or outbound, a refresh
// button for the next customer, and Easy, Medium or Hard for the customer.
//
// - A panel group button shows the one panel whose Choice line names the
//   pressed button in every panel group.
// - The level buttons show only the {{easy:}} / {{medium:}} / {{hard:}} lines
//   for that level, and only appear while the shown panel has any.
// - Track buttons ("track: Authorized, Not authorized") swap in the cards
//   tagged for that track, and only show while today's cards have a track.
// - Refresh moves every [Cycle:] in the block to its next card together. The
//   day picks the starting card, so teammates on separate screens match; the
//   number on the button lets them check.

const dayNumber = () => {
  const d = new Date();
  return Math.floor(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()) / 86400000);
};

function showPanel(box) {
  const segs = Array.from(box.querySelectorAll(":scope > .nw-choose-bar > .nw-choose-seg"));
  const key = segs.filter((s) => !s.classList.contains("nw-choose-levels") && !s.classList.contains("nw-choose-track"))
    .map((s) => s.querySelector('.nw-choose-opt[aria-pressed="true"]')?.getAttribute("data-val") || "")
    .join("|");
  let shown = null;
  box.querySelectorAll(":scope > .nw-choose-panel").forEach((p) => {
    p.hidden = p.getAttribute("data-choice") !== key;
    if (!p.hidden) shown = p;
  });
  const levels = segs.find((s) => s.classList.contains("nw-choose-levels"));
  if (levels) levels.hidden = !(shown && shown.querySelector(".nw-lv"));
  const track = segs.find((s) => s.classList.contains("nw-choose-track"));
  if (track) track.hidden = !(shown && shown.querySelector(".nw-cycle-card[data-track]"));
}

function showLevel(box) {
  const lv = box.getAttribute("data-level") || "";
  box.querySelectorAll(".nw-lv").forEach((s) => { s.hidden = s.getAttribute("data-lv") !== lv; });
}

function showCards(box) {
  const at = Number(box.getAttribute("data-at") || 0);
  let most = 0;
  box.querySelectorAll(".nw-cycle").forEach((c) => {
    // Track cards ([Card: ... | authorized]) stand in for the untagged ones
    // when that track is pressed; otherwise only untagged cards cycle.
    const all = Array.from(c.children).filter((x) => x.classList.contains("nw-cycle-card"));
    const tr = box.getAttribute("data-track") || "";
    const mine = all.filter((x) => x.getAttribute("data-track") === tr);
    const cards = mine.length ? mine : all.filter((x) => !x.hasAttribute("data-track"));
    most = Math.max(most, cards.length);
    all.forEach((card) => { card.hidden = true; });
    cards.forEach((card, i) => { card.hidden = i !== at % cards.length; });
  });
  const num = box.querySelector(":scope > .nw-choose-bar .nw-choose-num");
  if (num) num.textContent = most ? String((at % most) + 1) : "";
}

export function wireChoices(root) {
  if (!root) return undefined;
  root.querySelectorAll(".nw-choose").forEach((box) => {
    if (!box.hasAttribute("data-at")) box.setAttribute("data-at", String(dayNumber()));
    showPanel(box);
    showLevel(box);
    showCards(box);
  });
  const onClick = (e) => {
    const next = e.target?.closest?.(".nw-choose-next");
    if (next) {
      const box = next.closest(".nw-choose");
      if (!box) return;
      e.preventDefault();
      box.setAttribute("data-at", String(Number(box.getAttribute("data-at") || 0) + 1));
      showCards(box);
      return;
    }
    const btn = e.target?.closest?.(".nw-choose-opt");
    if (!btn) return;
    const box = btn.closest(".nw-choose");
    if (!box) return;
    e.preventDefault();
    btn.parentElement.querySelectorAll(".nw-choose-opt").forEach((b) => {
      b.setAttribute("aria-pressed", b === btn ? "true" : "false");
    });
    if (btn.parentElement.classList.contains("nw-choose-track")) {
      box.setAttribute("data-track", btn.getAttribute("data-val") || "");
      showCards(box);
      return;
    }
    if (btn.parentElement.classList.contains("nw-choose-levels")) {
      box.setAttribute("data-level", btn.getAttribute("data-val") || "");
      showLevel(box);
      return;
    }
    showPanel(box);
  };
  root.addEventListener("click", onClick);
  return () => root.removeEventListener("click", onClick);
}
