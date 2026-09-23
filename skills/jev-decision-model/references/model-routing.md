# Model Routing

The triage decision assigns each task to a **lane** (how much pipeline runs) and a **model tier** (which model does the reasoning-heavy steps). These are two independent axes — a narrow-scope MCP task can still need Opus if the stakes are high, and a wide-scope feature can stay on Sonnet if it's mostly repetitive.

## Complexity bands → lane

| `complexity_score` | Band | Default lane | Rationale |
|---|---|---|---|
| 0–2 | Trivial | `quick` | Single obvious change, no real design decision |
| 3–5 | Simple–moderate | `standard` (light) | Few files, low ambiguity, still worth one review pass |
| 6–8 | Moderate–high | `standard` (full) | Multiple files/modules, real integration points |
| 9–10 | High | `complex` | New architecture, wide blast radius, ambiguous requirements |

Overrides that apply regardless of score:
- `task_type` is `specific-task` or `mcp-task` → lane is `specific-mcp`, unless `complexity_score >= 9` (an unusually large MCP-centric task still gets `complex`).
- `task_type` is `research` → lane is `quick` (score ≤ 5) or `specific-mcp` (score > 5, when deep exploration is needed but no implementation follows).
- `needs_clarification.value == true` → surface the clarifying questions before entering any lane, regardless of score.

## Lane → model tier

| Lane | Agents used | Model(s) |
|---|---|---|
| `quick` | none (main thread executes directly) | inherited from the session (no override) |
| `specific-mcp` | `mcp-task-runner` (mcp-task) or direct execution (specific-task/research) | `sonnet`; escalate to `opus` if `complexity_score >= 7` or `high_stakes.value` is true |
| `standard` | 1x `task-explorer`, 1x `task-architect`, 1x `task-reviewer` | `sonnet` for explorer/reviewer; `sonnet` for architect at score 3–6, `opus` for architect at score 7–8 |
| `complex` | 2–3x `task-explorer` (parallel), 2–3x `task-architect` (parallel), 3x `task-reviewer` (parallel) | `sonnet` for explorers; `opus` for architects and at least one reviewer pass; implementation itself stays on the main thread's inherited model unless a specific step is flagged high-risk, in which case delegate that step to an `opus` agent |

## "Advanced model" tier

The `Agent` tool currently exposes `haiku`, `sonnet`, `opus`, and `fable` as selectable models. Treat `opus` as the ceiling of the `advanced` tier today. When a more capable model becomes available in the environment, update only this table — no command or agent file should hardcode a model name outside of this reference and the `model:` frontmatter it drives.

## Why the triage step itself runs on Haiku

A real JEV-style decision model is deliberately small and fast (the reference implementation reports 70–500ms latency) because the decision layer runs far more often than the work layer, and correctness there comes from a tight schema, not from raw model size. The `jev-triage` agent in this plugin follows the same principle: it runs on `haiku` with a strict JSON output contract, keeping triage cheap regardless of how expensive the downstream lane turns out to be.

This is also why `jev-triage` fires more than once per task (see `decision-primitives.md`'s "Secondary decision checkpoints"): the whole point of a cheap decision layer is that it's cheap enough to call repeatedly, so routing decisions throughout the pipeline — not just the initial one — get offloaded from Sonnet/Opus reasoning onto a bounded haiku classification instead.
