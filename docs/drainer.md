# LLM Parse Queue Drainer

> Last updated: 2026-05-15, session 5.
> Code lives in `docs/drainer.py` and as memory `accounting_rules / LLM Drainer v1.1 — built session 5`.

## What this is

A workbench-side Python function (`drain_llm_queue`) that processes
pending rows in `llm_parse_queue` using `invoke_llm()` — the free
Composio-hosted Groq endpoint that's only available inside
`COMPOSIO_REMOTE_WORKBENCH`. The Edge Function (`document-processor`)
cannot call `invoke_llm()` directly, so any LLM work that fails inside
the Edge Function is queued for this drainer to pick up.

## When to run

- **Manually from any Newtworks Claude session.** Just say "drain the queue"
  or call `drain_llm_queue()` in the workbench.
- **At the start of any session** where new bank-statement intake has
  happened since the last drain — to avoid backlog.
- **After any 'pending' row has been sitting > 1 hour** — the document
  processor will queue items eagerly; the drainer should not lag far.

## API

```python
drain_llm_queue(agency_id: str, limit: int = 10) -> dict
drain_llm_queue_until_empty(agency_id: str, max_iters: int = 20) -> dict
```

Both functions return a summary with `claimed`, `succeeded`, `failed`,
`retried`, plus per-item details.

## Behavior

- Atomic claim via `FOR UPDATE SKIP LOCKED` — safe to run multiple
  times concurrently without double-processing.
- Per-row max attempts: **3**. Hits 3 attempts → marks `failed` AND
  inserts a `tasks` row at `priority='high'` so the agent sees it.
- For `parse_bank_statement` purposes: after a successful LLM parse,
  runs the same downstream pipeline the Edge Function would have run:
  classify each txn → post balanced JE → create suspense task if the
  catch-all rule matched.
- For `suspense_guesses` purposes: stores the result_json; the suspense
  task UI reads it on next refresh. (Future enhancement: replace the
  lexical guess block in the task description with the real LLM ranking.)

## Source

See `docs/drainer.py` in this repo.
