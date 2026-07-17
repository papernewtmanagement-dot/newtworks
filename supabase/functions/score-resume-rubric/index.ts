// score-resume-rubric — DEPRECATED 2026-07-17
// Superseded by in-chat Opus scoring workflow (Peter reads resume_extracted_text in Claude chat,
// Claude scores as Opus 4.7, writes res_* columns to hiring_candidates). See session_note
// a96fc201 (2026-07-17 resume scoring Groq→in-chat pivot). Zero incremental cost, best model,
// Groq gpt-oss-120b calibration on anchor_low candidates was structurally unfixable.
//
// Full record removal (this leaves the row present as a tombstone; MCP has no delete tool):
//   supabase functions delete score-resume-rubric --project-ref vulhdujhbwvibbojiimi

Deno.serve(() =>
  new Response(
    JSON.stringify({
      ok: false,
      error: "gone",
      code: 410,
      message: "score-resume-rubric is deprecated. Resume scoring runs in-chat via Claude Opus.",
      successor: "in-chat-opus-scoring",
      deprecated_at: "2026-07-17",
    }),
    {
      status: 410,
      headers: { "Content-Type": "application/json" },
    },
  )
);
