import { T } from "./theme.js";

// ============================================================
// SHARED MANUAL BODY STYLES
//
// The CSS that styles HTML produced by src/lib/markdown.js. It used to live
// inline inside Manual.jsx, which meant any other module rendering manual
// content with className="newtworks-handbook-body" got no styling at all
// unless Manual.jsx happened to be mounted. Lifted out verbatim 2026-09-14 so
// every caller renders the same thing from one place.
//
// Two parts, on purpose:
//   MANUAL_BODY_CSS  — screen styles. Every rule is scoped to a manual class,
//                      so it is safe to mount anywhere.
//   MANUAL_PRINT_CSS — the print rules. These hide EVERYTHING on the page and
//                      un-hide only .nw-manual-print, so they must only be
//                      mounted by the full manual page view. Mounting them
//                      inside another module would break that module's own
//                      print output.
//
// Callers:
//   <ManualBodyStyles includePrint />  → Manual.jsx (the full page view)
//   <ManualBodyStyles />               → anywhere embedding manual content
// ============================================================

export const MANUAL_BODY_CSS = `
        .newtworks-handbook-body { font-size: 14px; line-height: 1.75; color: ${T.slate700}; }
        .newtworks-handbook-body h1 { font-size: 24px; font-weight: 800; color: ${T.slate900}; margin: 28px 0 12px 0; letter-spacing: -0.02em; }
        .newtworks-handbook-body h2 { font-size: 19px; font-weight: 700; color: ${T.slate900}; margin: 36px 0 14px 0; padding: 8px 12px; letter-spacing: -0.015em; background: linear-gradient(to right, ${T.blue}22, transparent 65%); border-left: 3px solid ${T.blue}; border-radius: 6px; }
        .newtworks-handbook-body .newtworks-info-btn { display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; padding: 0; margin: 0 2px; border: 1px solid ${T.blue}55; background: ${T.blue}11; color: ${T.blue}; font-size: 12px; line-height: 1; font-family: inherit; vertical-align: baseline; cursor: pointer; border-radius: 50%; }
        .newtworks-handbook-body .newtworks-info-btn:hover, .newtworks-handbook-body .newtworks-info-btn:focus-visible { background: ${T.blue}33; border-color: ${T.blue}; outline: none; }
        .newtworks-info-popover { padding: 12px 14px; max-width: min(360px, calc(100vw - 32px)); border: 1px solid ${T.blue}; border-radius: 6px; background: white; color: ${T.slate900}; font-size: 14px; line-height: 1.5; box-shadow: 0 8px 24px rgba(0,0,0,0.12); }
        .newtworks-info-popover a { color: ${T.blue}; text-decoration: underline; }
        .newtworks-handbook-body h3 { font-size: 16px; font-weight: 700; color: ${T.slate900}; margin: 26px 0 10px 0; padding: 5px 10px; background: linear-gradient(to right, ${T.blue}14, transparent 50%); border-left: 3px solid ${T.blue}66; border-radius: 5px; }
        .newtworks-handbook-body h4 { font-size: 14px; font-weight: 700; color: ${T.slate800}; margin: 20px 0 8px 0; padding: 3px 0 3px 9px; border-left: 2px solid ${T.slate300}; }
        .newtworks-handbook-body p { margin: 0 0 14px 0; }
        .newtworks-handbook-body ul, .newtworks-handbook-body ol { margin: 8px 0 16px 0; padding-left: 24px; }
        .newtworks-handbook-body li { margin-bottom: 6px; }
        .newtworks-handbook-body strong { font-weight: 700; color: ${T.slate900}; }
        .newtworks-handbook-body em { font-style: italic; }
        .newtworks-handbook-body code { background: ${T.slate100}; padding: 1px 6px; border-radius: 4px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; color: ${T.slate800}; }
        .newtworks-handbook-body pre { background: ${T.slate100}; padding: 14px 16px; border-radius: 8px; overflow-x: auto; margin: 14px 0; }
        .newtworks-handbook-body pre code { background: transparent; padding: 0; }
        .newtworks-handbook-body a { color: ${T.blue}; text-decoration: underline; text-decoration-color: ${T.blue}66; }
        .newtworks-handbook-body a:hover { text-decoration-color: ${T.blue}; }
        .newtworks-handbook-body hr { border: 0; border-top: 1px solid ${T.slate200}; margin: 24px 0; }
        .newtworks-handbook-body blockquote {
          background: ${T.blueLt};
          border-left: 4px solid ${T.blue};
          padding: 12px 16px;
          margin: 14px 0;
          border-radius: 6px;
          color: ${T.slate700};
        }
        .newtworks-handbook-body blockquote p { margin: 0 0 6px 0; }
        .newtworks-handbook-body blockquote p:last-child { margin-bottom: 0; }
        /* Info-box blockquotes (Knowledge & FAQ sections) carry their own left
           border + tint so they stand out on a plain page. Inside an OPEN
           expander that surface already exists - the blockquotes own border
           was showing as a second colored line nested inside the containers
           shading. Peter 2026-08-08. Neutralize only in that context; leave the
           standalone blockquote style untouched everywhere else. */
        .newtworks-handbook-body details[open] blockquote {
          background: transparent;
          border-left: none;
          border-radius: 0;
          padding: 4px 0;
          margin: 10px 0;
        }
        .newtworks-handbook-body table {
          border-collapse: collapse;
          margin: 16px 0;
          width: 100%;
          font-size: 13px;
        }
        .newtworks-handbook-body th, .newtworks-handbook-body td {
          border: 1px solid ${T.slate200};
          padding: 8px 12px;
          text-align: left;
          vertical-align: top;
        }
        .newtworks-handbook-body th { background: ${T.slate50}; font-weight: 700; color: ${T.slate900}; }
        /* Expanders — literal port of the approved preview file
           (expander_v4_preview.html), shipped 2026-08-08. Same hex values, same
           paddings, same plain-triangle caret — not translated through design
           tokens or redesigned. Do not "improve" this without a new preview
           approved first; that is exactly what went wrong last time. */
        .newtworks-handbook-body .nw-rp { margin: 8px 0 2px 0; }
        .newtworks-handbook-body .nw-rp-card[hidden] { display: none !important; }
        .newtworks-handbook-body .nw-rp-bar { display: flex; align-items: center; gap: 6px; margin: 0 0 8px 0; }
        .newtworks-handbook-body .nw-rp-bar .nw-rp-select { flex: 1 1 auto; min-width: 0; width: 100%; }
        .newtworks-handbook-body .nw-rp-inline, .newtworks-handbook-body .nw-rp-inline .nw-rp-cards { display: inline; margin: 0; }
        .newtworks-handbook-body .nw-rp-inline .nw-rp-card { display: inline; background: none; padding: 0; border-radius: 0; }
        .newtworks-handbook-body .nw-rp-inline .nw-rp-next { font-size: 12px; padding: 1px 6px; margin-right: 2px; vertical-align: baseline; }
        .newtworks-handbook-body .nw-rp-select {
          font: inherit; font-size: 13px; padding: 4px 8px; margin: 0; min-width: 0;
          border: 1px solid #CBD5C0; border-radius: 6px; background: #fff; max-width: 100%;
        }
        .newtworks-handbook-body .nw-rp-next {
          font: inherit; font-size: 15px; line-height: 1; padding: 4px 8px; cursor: pointer;
          border: 1px solid #CBD5C0; border-radius: 6px; background: #fff; color: #334155;
        }
        .newtworks-handbook-body .nw-rp-next:hover { background: #F8FAF3; }
        .newtworks-handbook-body .nw-rp-card {
          background: #F8FAF3; border-radius: 7px; padding: 8px 12px;
        }
        .newtworks-handbook-body .nw-rp-card p { margin: 4px 0; }
        .newtworks-handbook-body .nw-rp-card details { margin: 6px 0 2px 0; }
        .newtworks-handbook-body details { margin: 6px 0 6px 10px; }
        .newtworks-handbook-body details:not([open]) { background: #F8FAF3; border-radius: 7px; }
        .newtworks-handbook-body details:not([open]) > summary { padding: 8px 12px 8px 30px; }
        .newtworks-handbook-body details[open] {
          background: #F1F4E9;
          border-radius: 7px;
          overflow: hidden;
          margin-bottom: 14px;
        }
        .newtworks-handbook-body details[open] > summary {
          background: #F8FAF3;
          padding: 8px 12px 8px 30px;
          margin: 0;
        }
        .newtworks-handbook-body summary {
          cursor: pointer;
          font-weight: 600;
          color: ${T.slate700};
          position: relative;
          user-select: none;
          list-style: none;
        }
        .newtworks-handbook-body summary::-webkit-details-marker { display: none; }
        .newtworks-handbook-body summary::before {
          content: "▸";
          position: absolute;
          left: 10px;
          top: 9px;
          color: ${T.blue};
          font-size: 11px;
          font-weight: 700;
        }
        .newtworks-handbook-body details[open] > summary::before { content: "▾"; }
        .newtworks-handbook-body details[open] > *:not(summary) {
          margin: 0;
          padding: 4px 30px;
          background: transparent;
        }
        .newtworks-handbook-body details[open] > summary + * { padding-top: 10px; }
        .newtworks-handbook-body details[open] > *:last-child { padding-bottom: 12px; }
        /* Lists inside an OPEN expander get the SAME indent step they have on a
           normal page. Peter 2026-08-10: "when bullets are not inside an
           expanding section, they always indent a certain amount when compared
           to normal text. Within an expanding section, they do not."
           WHY IT BROKE: the rule directly above sets padding: 4px 30px on every
           direct child of an open expander. 30px is what lines body text up with
           the summary label - but it is the SHORTHAND, so it also overwrote the
           padding-left: 24px that ul/ol carry from the element rule higher up.
           Lists ended up flush with the body text instead of stepped in from it,
           and the bullet glyphs hung out to its left. 54px = the 30px body
           alignment + the same 24px step lists use everywhere else.
           Only padding-left is set here, so the 4px top/bottom and 30px right
           from the shorthand above still apply. Same specificity as that rule
           (0,2,2) and it comes LATER, which is what makes it win - do not move
           it above that rule or it becomes dead CSS. */
        .newtworks-handbook-body details[open] > :is(ul, ol) { padding-left: 54px; }
        .newtworks-handbook-body img { max-width: 100%; height: auto; border-radius: 6px; }
        /* Included-section quick-edit pencil — dropped in front of every
           resolved [Included from:] / [Embedded excerpt from:] block when
           markTransclusions is on (admins, view mode only). Floated so it
           sits at the top-right of the block it belongs to without wrapping
           the block's own markdown in an element (see markdown.js). */
        .newtworks-handbook-body .nw-transclusion-edit-btn-wrap { float: right; margin: 2px 0 6px 10px; }
        .newtworks-handbook-body .nw-transclusion-edit-btn {
          display: inline-flex; align-items: center; justify-content: center;
          width: 22px; height: 22px; padding: 0; border-radius: 50%;
          border: 1px solid ${T.blue}55; background: ${T.blueLt}; color: ${T.blue};
          font-size: 12px; line-height: 1; cursor: pointer;
        }
        .newtworks-handbook-body .nw-transclusion-edit-btn:hover,
        .newtworks-handbook-body .nw-transclusion-edit-btn:focus-visible {
          background: ${T.blue}33; border-color: ${T.blue}; outline: none;
        }
        /* ─── BODY CONTENT INDENT — MUST STAY LAST IN THIS BLOCK ───
           Peter 2026-08-08. Body content sits 12px in from its header so it
           stands apart; headers stay flush.
           WHY IT LIVES AT THE BOTTOM: the first two attempts set margin-left
           near the top of this style block and were SILENTLY CANCELED. The
           element rules further down use the margin SHORTHAND
           (p -> margin: 0 0 14px 0; ul/ol -> margin: 8px 0 16px 0; blockquote
           and pre -> margin: 14px 0; table -> margin: 16px 0), and a shorthand
           resets every side including left. Equal specificity, later rule wins,
           so the indent was dead CSS - it shipped in the bundle and changed
           nothing on screen. :is() also lifts specificity above the bare
           element rules so ordering alone isn't the only defence.
           If you add element margin rules, add them ABOVE this, never below. */
        .newtworks-handbook-body > :is(p, ul, ol, blockquote, pre, details, table, .newtworks-table-wrap) {
          margin-left: 12px;
        }
        .newtworks-handbook-body > :is(table, .newtworks-table-wrap) {
          width: calc(100% - 12px);
        }

`;

export const MANUAL_PRINT_CSS = `
        /* --- PRINTING: TITLE AND CONTENT ONLY ---
           Peter 2026-08-19: a manual page must print as nothing but its title
           and its text. Everything else on the screen goes away - the app's top
           bar, the left-hand module list, the section list beside the page, the
           edit buttons, the little label chips above the title, and the white
           card frame the text sits inside.

           HOW IT WORKS: hide every element on the page, then un-hide just the
           print root, and lift that root out of the app's fixed-height,
           scrolling layout by positioning it at the top-left corner of the
           sheet. Without that lift only the first screenful would print,
           because the app shell clips and scrolls everything inside it. Same
           approach already in use for the Financials print package.

           MARGINS ON PURPOSE: every margin below is written as margin-top /
           margin-bottom, never the margin shorthand. The rules further up this
           block indent body content 12px from the left using margin-left, and
           a shorthand would silently wipe that out - the same trap already
           documented above. Do not "tidy" these into shorthand. */
        @media print {
          html, body { height: auto !important; overflow: visible !important; background: #fff !important; }
          body * { visibility: hidden !important; }
          .nw-manual-print, .nw-manual-print * { visibility: visible !important; }
          .nw-manual-print {
            position: absolute !important; left: 0 !important; top: 0 !important;
            width: 100% !important; max-width: none !important;
            margin-top: 0 !important; margin-bottom: 0 !important;
            padding: 0 !important;
          }
          /* Anything wearing this class is screen-only chrome. display:none beats
             the visibility rule above, so these never take up print space. */
          .nw-print-hide, .nw-print-hide * { display: none !important; }
          .nw-manual-print-title {
            font-size: 20pt !important; color: #000 !important;
            margin-top: 0 !important; margin-bottom: 14pt !important;
          }
          /* The card frame becomes plain paper. */
          .nw-manual-print-card {
            background: #fff !important; border: 0 !important; border-radius: 0 !important;
            box-shadow: none !important; padding: 0 !important;
          }
          .newtworks-handbook-body { font-size: 11pt !important; line-height: 1.55 !important; color: #000 !important; }
          .newtworks-handbook-body :is(h1, h2, h3, h4) {
            color: #000 !important;
            break-after: avoid; page-break-after: avoid;
          }
          .newtworks-handbook-body h2 {
            background: none !important; border-left: 2pt solid #444 !important;
            border-radius: 0 !important; padding: 2pt 0 2pt 8pt !important;
          }
          .newtworks-handbook-body h3 {
            background: none !important; border-left: 1pt solid #777 !important;
            border-radius: 0 !important; padding: 1pt 0 1pt 7pt !important;
          }
          .newtworks-handbook-body h4 {
            border-left: 1pt solid #aaa !important; padding: 0 0 0 7pt !important;
          }
          .newtworks-handbook-body a { color: #000 !important; text-decoration: underline; }
          .newtworks-handbook-body code, .newtworks-handbook-body pre { background: none !important; }
          .newtworks-handbook-body pre { border: 1pt solid #999 !important; white-space: pre-wrap !important; }
          .newtworks-handbook-body blockquote {
            background: none !important; border-left: 2pt solid #999 !important; border-radius: 0 !important;
          }
          /* Expanders print open and flat. The matching JavaScript below opens
             every one of them before the print dialog runs and puts them back
             afterwards - closed panels are hidden by the browser itself, which
             CSS alone cannot reliably undo. These rules strip the on-screen
             tinted panel and keep an expander from splitting across sheets. */
          .newtworks-handbook-body details,
          .newtworks-handbook-body details[open] {
            background: none !important; border-radius: 0 !important;
            height: auto !important; overflow: visible !important;
            margin-top: 6pt !important; margin-bottom: 6pt !important;
            break-inside: avoid; page-break-inside: avoid;
          }
          .newtworks-handbook-body details > summary {
            background: none !important; padding: 0 0 0 12pt !important;
          }
          .newtworks-handbook-body details > *:not(summary) {
            display: block !important; content-visibility: visible !important;
            padding: 2pt 0 2pt 12pt !important;
          }
          .newtworks-handbook-body details[open] > :is(ul, ol) { padding-left: 30pt !important; }
          /* KEEPING BULLETS WHOLE, WITHOUT STRANDING A PAGE: a bullet that
             holds its own sub-bullets is a whole section of the page and is
             often taller than a sheet of paper. Telling the browser to keep one
             of those in a single piece makes it jump wholesale to the next
             sheet and leave whatever came before it alone on the sheet before -
             the 09/03 course page printed its one-line video note by itself on
             page one and started the first section on page two. So only bullets
             with nothing nested inside them are held together; a bullet with
             sub-bullets is allowed to break between its children. A browser too
             old for :has() throws that line away and simply lets every bullet
             break, which is the safe outcome, not the broken one. */
          .newtworks-handbook-body li { break-inside: auto; page-break-inside: auto; }
          .newtworks-handbook-body li li {
            break-inside: avoid; page-break-inside: avoid;
          }
          .newtworks-handbook-body li:not(:has(ul)):not(:has(ol)) {
            break-inside: avoid; page-break-inside: avoid;
          }
          .newtworks-handbook-body tr {
            break-inside: avoid; page-break-inside: avoid;
          }
          .newtworks-handbook-body table { font-size: 9.5pt !important; }
          .newtworks-handbook-body th { background: none !important; }
          /* On screen wide tables scroll sideways inside a box. On paper the box
             would cut them off, so it stops clipping. */
          .newtworks-table-wrap { overflow: visible !important; }
          .newtworks-handbook-body img { max-width: 100% !important; }
        }
`;

export function ManualBodyStyles({ includePrint = false }) {
  return <style>{includePrint ? `${MANUAL_BODY_CSS}\n${MANUAL_PRINT_CSS}` : MANUAL_BODY_CSS}</style>;
}
