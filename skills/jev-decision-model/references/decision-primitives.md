# Decision Primitives

Three structured primitives compose every JEV-style triage decision. Each primitive returns a typed value, never free text — this is what keeps the decision layer fast, cheap, and impossible to misparse downstream.

## Noul — bounded yes/no

A probability-backed boolean. Used for gate conditions that must resolve to a clear branch.

Fields: `value` (true/false), `confidence` (0.0–1.0).

Used in this plugin for:
- `needs_clarification` — does the request contain a real ambiguity that blocks safe execution?
- `needs_mcp` — is an MCP tool central to completing the task (not just incidentally useful)?
- `needs_multiagent` — does the scope justify parallel exploration/architecture/review, or would that be pure overhead?
- `high_stakes` — is this hard or costly to reverse if done wrong (sending a message, deleting/overwriting records others can see, posting publicly, a schema migration, an auth/payment change)? False for ordinary reversible code edits.

Low-confidence Nouls (confidence < 0.6) don't all get the same treatment: a low-confidence `needs_clarification` should resolve to true **and** be surfaced to the user (via `AskUserQuestion`) before proceeding, since missing a real ambiguity is the one failure mode this flag exists to catch. A low-confidence `needs_mcp`, `needs_multiagent`, or `high_stakes` should also resolve to true (over-provisioning effort/caution is cheaper than under-provisioning it), but only `needs_clarification` needs to interrupt the user by itself — `high_stakes` still triggers a confirm-before-executing step downstream regardless of confidence, but that's a different mechanism (see the `specific-mcp` lane and `mcp-task-runner`), not an extra clarifying question here.

## Escolha — selection among predefined options

A closed-set classification. Never invent a category outside the set; if nothing fits well, pick the closest and note it in `reasoning`.

Used in this plugin as `task_type`, one of: `feature`, `bugfix`, `refactor`, `specific-task`, `mcp-task`, `research`. See `task-taxonomy.md` for definitions and examples of each.

## Pontuação — scored evaluation on a scale

A calibrated 0–10 score, not a vibe. Used in this plugin as `complexity_score`, evaluated against concrete criteria:

- Number of files/modules touched
- Number of independent design decisions required
- Number of integration points with existing systems
- Degree of ambiguity in the request itself
- Blast radius if the implementation is wrong (local bug vs. architectural regression)

See `model-routing.md` for how the score maps to lanes and models.

## Output contract

Every triage decision is a single structured block, produced before any other work starts:

```json
{
  "task_type": "feature | bugfix | refactor | specific-task | mcp-task | research",
  "complexity_score": 0,
  "needs_clarification": { "value": false, "confidence": 0.9 },
  "needs_mcp": { "value": false, "confidence": 0.9 },
  "needs_multiagent": { "value": false, "confidence": 0.9 },
  "high_stakes": { "value": false, "confidence": 0.9 },
  "recommended_lane": "quick | specific-mcp | standard | complex",
  "recommended_model": "none | sonnet | opus",
  "source": "openjev | groq-direct | self",
  "reasoning": "one or two sentences justifying the above"
}
```

`recommended_model` never names `haiku` — that tier is what the triage step itself runs on (see below), not something a lane routes its work to. `source` records whether the classification came from the external decision layer or from Claude's own judgment (`self`).

This mirrors what a real JEV-style decision model returns: typed, bounded, impossible to hallucinate outside the schema.

## External decision layer (optional)

The `jev-triage` agent does not only self-classify — it first tries `scripts/jev-decide.sh`, which can call a real, open-source JEV-style decision engine:

- **[OpenJev](https://github.com/SiliconLabAI/OpenJev)** (SiliconLabAI, MIT-licensed) — an open reimplementation of the same "state + typed questions → structured answers" pattern, supporting the exact `choice`/`score`/`noul` primitives used here. Point `OPENJEV_URL` at a running instance (`npm run dev` locally, or a hosted one) to use it.
- **Groq direct** — when `OPENJEV_URL` isn't set but `GROQ_API_KEY` is, the script calls Groq's OpenAI-compatible API directly, replicating OpenJev's own "oneshot" backend prompt/response contract (Groq's low latency — sub-second — makes this a good fit for a triage step that should stay cheap and fast). OpenJev's own client code also recognizes `GROQ_API_KEY` natively if you'd rather run OpenJev itself against Groq.
- **Neither configured** → the script exits non-zero with no output, and `jev-triage` falls back to classifying the task itself (still on `haiku`, still bounded to the same schema). This is the expected zero-setup default, not a degraded mode — see `SKILL.md`'s design principle: decide small, execute big.

See `scripts/jev-decide.sh` and `.env.example` at the plugin root for exact configuration.

## Secondary decision checkpoints (mid-pipeline)

The initial triage above only fires once, at the very start. To keep decisions cheap throughout the whole pipeline — not just at the entry point — `/smart-task`'s `standard` and `complex` lanes call the `jev-triage` agent two more times, for narrower questions that only make sense once more information exists. Both run on `haiku`, self-classified (they aren't part of `jev-decide.sh`'s fixed external schema):

- **Re-triage**, right after exploration: `{"needs_escalation": {value, confidence}, "revised_complexity_score": 0-10, "reasoning": "..."}`. Catches a task that was under-scored at Phase 0 (the explorer found real complexity the one-line request didn't reveal) before Sonnet/Opus tokens get spent on an architecture pass that's too shallow for the actual scope.
- **Review-routing**, right after review: `{"review_outcome": "proceed | fix_critical_now | ask_user", "confidence": 0-1, "reasoning": "..."}`. Replaces free-form "decide what to do with these findings" reasoning with a bounded three-way choice.

Both exist for the same reason the primary triage does: a structured, cheap decision beats spending an expensive model's reasoning tokens on something that's really just a routing call. See `agents/jev-triage.md` for the exact schemas and `commands/smart-task.md` for where each fires.

**Known reliability limitation, tested live**: unlike the primary full-triage call (a plain task request, which reliably comes back as clean JSON), these two secondary checkpoints receive content that reads like "findings to review" — and `haiku` has a strong tendency to answer with a full prose report instead of the compact schema, even with an explicit `MODE:` marker and repeated "output only JSON" instructions reinforced with negative examples. Across two rounds of prompt strengthening this reproduced 4/4 times on the secondary checkpoints (0/2 times on primary triage). Rather than keep iterating on prompt wording indefinitely, `commands/smart-task.md`'s checkpoint steps are written to be tolerant of either shape: read the JSON field when it's there, read the stated conclusion from the prose when it isn't, and fall back to the conservative default (no escalation for re-triage; `ask_user` for review-routing) when genuinely unclear. The cost savings still mostly hold — `haiku` still does the actual judgment work either way — but the contract isn't as clean as the primary triage's.
