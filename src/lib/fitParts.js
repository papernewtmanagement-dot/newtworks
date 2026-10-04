// The ten parts of a FIT conversation, in the order a conversation runs.
// ONE list. The conversation scorecard (Log, History, Live) and the Live tab's
// script walker both read it, so a part is never named two ways.
//
//   key      — the fit_scorecards column the score lands in
//   label    — the full name
//   short    — the name on a small tag or score button
//   excerpt  — the shared manual fragment that opens this part on every FIT
//              page (Processes > FIT Conversations). The Live tab finds where
//              each part starts by finding this fragment.
export const CARD_PARTS = [
  { key: "demeanor_score",        label: "Demeanor",              short: "Demeanor",    excerpt: "Demeanor Header" },
  { key: "frogs_score",           label: "FROGS",                 short: "FROGS",       excerpt: "FROGS Header" },
  { key: "intro_score",           label: "Intro",                 short: "Intro",       excerpt: "Intro" },
  { key: "eligibility_score",     label: "Determine Eligibility", short: "Eligibility", excerpt: "Eligibility" },
  { key: "setup_gnc_score",       label: "Setup GNC",             short: "Setup GNC",   excerpt: "Setup GNC" },
  { key: "uncover_gap_score",     label: "Uncover the Gap",       short: "Uncover",     excerpt: "Uncover the Gap Header" },
  { key: "bridge_gap_score",      label: "Bridge the Gap",        short: "Bridge",      excerpt: "Bridge the Gap" },
  { key: "customize_close_score", label: "Customize & Close",     short: "Close",       excerpt: "Customize Header" },
  { key: "set_followup_score",    label: "Set FU",                short: "Set FU",      excerpt: "Next Steps" },
  { key: "review_referral_score", label: "Review & Referral",     short: "Rev & Ref",   excerpt: "Review & Referral" },
];

// What each score means. The Log's scorecard row and the Live tab's tag both show these.
export const SCORE_MEANING = {
  0: "Didn't do it",
  1: "Did it poorly, didn't land",
  2: "Did it well, didn't land",
  3: "Did it well, landed",
};
