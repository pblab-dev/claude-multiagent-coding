# Decision Primitives

Three structured primitives compose every JEV-style triage decision. Each primitive returns a typed value, never free text — this is what keeps the decision layer fast, cheap, and impossible to misparse downstream.

## Noul — bounded yes/no

A probability-backed boolean. Used for gate conditions that must resolve to a clear branch.

Fields: `value` (true/false), `confidence` (0.0–1.0).

Used in this plugin for:
- `needs_clarification` — does the request contain a real ambiguity that blocks safe execution?
- `needs_mcp` — is an MCP tool central to completing the task (not just incidentally useful)?
- `needs_multiagent` — does the scope justify parallel exploration/architecture/review, or would that be pure overhead?

Low-confidence Nouls (confidence < 0.6) should default to the safer branch: treat `needs_clarification` as true, treat `needs_multiagent` as true (over-provisioning effort is cheaper than under-provisioning it).

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
  "recommended_lane": "quick | specific-mcp | standard | complex",
  "recommended_model": "haiku | sonnet | opus",
  "reasoning": "one or two sentences justifying the above"
}
```

This mirrors what a real JEV-style decision model returns: typed, bounded, impossible to hallucinate outside the schema.

## External decision layer (optional)

The `jev-triage` agent does not only self-classify — it first tries `scripts/jev-decide.sh`, which can call a real, open-source JEV-style decision engine:

- **[OpenJev](https://github.com/SiliconLabAI/OpenJev)** (SiliconLabAI, MIT-licensed) — an open reimplementation of the same "state + typed questions → structured answers" pattern, supporting the exact `choice`/`score`/`noul` primitives used here. Point `OPENJEV_URL` at a running instance (`npm run dev` locally, or a hosted one) to use it.
- **Groq direct** — when `OPENJEV_URL` isn't set but `GROQ_API_KEY` is, the script calls Groq's OpenAI-compatible API directly, replicating OpenJev's own "oneshot" backend prompt/response contract (Groq's low latency — sub-second — makes this a good fit for a triage step that should stay cheap and fast). OpenJev's own client code also recognizes `GROQ_API_KEY` natively if you'd rather run OpenJev itself against Groq.
- **Neither configured** → the script exits non-zero with no output, and `jev-triage` falls back to classifying the task itself (still on `haiku`, still bounded to the same schema). This is the expected zero-setup default, not a degraded mode — see `SKILL.md`'s design principle: decide small, execute big.

See `scripts/jev-decide.sh` and `.env.example` at the plugin root for exact configuration.
