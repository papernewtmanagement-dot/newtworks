// src/lib/choices.js
//
// Clicks for [Choose:] blocks (see markdown.js). Pressing a button marks it in
// its group, then shows the one panel whose Choice line names the pressed
// button in every group. Peter 2026-10-07: the kickoff role play pop-up,
// team member or customer, inbound or outbound.

export function wireChoices(root) {
  if (!root) return undefined;
  const onClick = (e) => {
    const btn = e.target?.closest?.(".nw-choose-opt");
    if (!btn) return;
    const box = btn.closest(".nw-choose");
    if (!box) return;
    e.preventDefault();
    btn.parentElement.querySelectorAll(".nw-choose-opt").forEach((b) => {
      b.setAttribute("aria-pressed", b === btn ? "true" : "false");
    });
    const bar = box.querySelector(":scope > .nw-choose-bar");
    const key = Array.from(bar ? bar.querySelectorAll(":scope > .nw-choose-seg") : [])
      .map((seg) => seg.querySelector('.nw-choose-opt[aria-pressed="true"]')?.getAttribute("data-val") || "")
      .join("|");
    box.querySelectorAll(":scope > .nw-choose-panel").forEach((p) => {
      p.hidden = p.getAttribute("data-choice") !== key;
    });
  };
  root.addEventListener("click", onClick);
  return () => root.removeEventListener("click", onClick);
}
