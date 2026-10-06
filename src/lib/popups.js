// src/lib/popups.js
//
// Pop-ups on manual pages. Peter 2026-10-06: the Daily Kickoff's Week 1 call
// scripts open in a pop-up, built from the shared script pieces, so nobody has
// to piece the call together from other pages.
//
// Written in a page as an expander with the class nw-popup:
//
//   <details class="nw-popup">
//   <summary>Inbound call</summary>
//   ...markdown, shared excerpts, role plays...
//   </details>
//
// markdown.js renders it like any expander, so anywhere this file is not wired
// it still works as one. On a manual page wirePopups() swaps each one for a
// button and a dialog holding the same content: full screen on a phone, a
// centered panel on a wide screen. Closes with the X, Escape, the phone's back
// gesture, or a tap outside it.

export function wirePopups(root) {
  if (!root || typeof document === "undefined") return;
  root.querySelectorAll("details.nw-popup").forEach((d) => {
    const summary = d.querySelector(":scope > summary");
    const label = String(summary?.textContent || "").trim() || "Open";

    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "nw-popup-btn";
    btn.textContent = label;

    const dlg = document.createElement("dialog");
    dlg.className = "nw-popup-dialog";
    dlg.setAttribute("aria-label", label);

    const bar = document.createElement("div");
    bar.className = "nw-popup-bar";
    const title = document.createElement("strong");
    title.textContent = label;
    const close = document.createElement("button");
    close.type = "button";
    close.className = "nw-popup-close";
    close.setAttribute("aria-label", "Close");
    close.textContent = "\u2715";
    bar.append(title, close);

    const body = document.createElement("div");
    body.className = "nw-popup-body";
    Array.from(d.childNodes).forEach((n) => { if (n !== summary) body.appendChild(n); });
    dlg.append(bar, body);

    const shut = () => {
      if (typeof dlg.close === "function") dlg.close();
      else dlg.removeAttribute("open");
    };
    btn.addEventListener("click", () => {
      if (typeof dlg.showModal === "function") dlg.showModal();
      else dlg.setAttribute("open", "");
      body.scrollTop = 0;
    });
    close.addEventListener("click", shut);
    // A tap on the dimmed area outside the panel lands on the dialog itself.
    dlg.addEventListener("click", (e) => { if (e.target === dlg) shut(); });

    d.replaceWith(btn, dlg);
  });
}
