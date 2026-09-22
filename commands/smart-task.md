---
description: Multiuse task command that routes work through a JEV-style triage step into the right effort lane and model tier
argument-hint: Task description (feature, bugfix, specific task, or MCP task)
---

# Smart Task

You are handling a request of unknown shape and size: it could be a one-line fix, a full feature, a narrow specific task, or a task centered on an MCP tool. Do not assume the effort level — classify first, then execute at the effort level the classification justifies. Never run the full multi-agent pipeline on a trivial request, and never shortcut a genuinely complex one.

Use TodoWrite to track phases once a lane is chosen.

Initial request: $ARGUMENTS

---

## Phase 0: JEV Triage (mandatory, always first)

**Goal**: Classify the request and decide the lane + model tier before any other action.

**Actions**:
1. Launch the `jev-triage` agent with the raw request (and, if this is a follow-up in an ongoing conversation, a one-paragraph summary of relevant prior context — do not paste the whole conversation).
2. Parse its structured JSON output: `task_type`, `complexity_score`, the three Noul flags, `recommended_lane`, `recommended_model`, `reasoning`.
3. If `needs_clarification.value` is true, pause and ask the user via `AskUserQuestion` before proceeding — do not guess past a genuine ambiguity. (A low-confidence `needs_mcp`/`needs_multiagent` does not need this — `jev-triage` already resolved it to the safer, more-effort default on its own.)
4. Briefly tell the user the decision in one line before proceeding, e.g.: "Classificado como `bugfix`, complexidade 3/10 → lane `standard`, modelo `sonnet`." This is the audit trail — always show it, even for `quick` lane tasks.
5. Enter the lane indicated by `recommended_lane` (task_type overrides, e.g. `specific-task`/`mcp-task`/`research`, take precedence over the plain complexity-score bands — see the lane headers below and `jev-triage`'s routing table for exactly which wins). If the user explicitly asks for a different lane than recommended (e.g. "faz isso rápido, sem essa cerimônia toda" or "quero o pipeline completo mesmo sendo simples"), honor their override and say you're doing so.

---

## Lane: `quick` (complexity 0–2 and task_type in feature/bugfix/refactor, or `research` at complexity ≤5)

**Goal**: Get a trivial or read-only request done with minimal ceremony.

**Actions**:
1. Execute directly on the main thread — no sub-agents, no model override.
2. Read only the files strictly necessary.
3. Make the change (or produce the answer, for `research`).
4. Run any obviously-relevant fast check (e.g. a linter already configured, a quick type check) if one exists and is fast; do not set up new tooling for this.
5. Report done in 1-3 sentences. Skip the full Phase Summary format below — it's disproportionate for this lane.

---

## Lane: `specific-mcp` (task_type `specific-task` or `mcp-task` at complexity < 9 — this overrides the complexity-only bands above and below — or `research` at complexity >5)

**Goal**: Execute a narrow, well-defined request — whether it's a mechanical code change or an MCP-tool-centered action — correctly and efficiently.

**Actions**:
1. If `needs_mcp.value` is true: launch the `mcp-task-runner` agent with the exact request and any relevant IDs/context already known. Model: `sonnet`, or `opus` if `complexity_score >= 7` or the action is hard to reverse (per `jev-triage`'s flag).
2. If `needs_mcp.value` is false (a `specific-task` that's purely local): execute directly, same as `quick` lane, but do a `git diff` self-check afterward since these are still real code changes, not just answers.
3. For genuinely hard-to-reverse MCP actions (sending messages, deleting/overwriting records others can see, posting publicly), confirm with the user before the `mcp-task-runner` agent executes them — do not let the agent assume prior approval it wasn't actually given.
4. Report done with: what was done, what tool/file was touched, and the observed result.

---

## Lane: `standard` (complexity 3–8 and task_type in feature/bugfix/refactor)

**Goal**: Build or fix something real without the overhead of a full parallel multi-agent pipeline.

**Actions**:
1. **Explore**: launch one `task-explorer` agent (model `sonnet`) targeted at the relevant area. Read the files it flags as essential.
2. **Clarify**: if the explorer surfaces ambiguity the triage step didn't catch, ask the user now via `AskUserQuestion` — before designing anything.
3. **Design**: launch one `task-architect` agent (model `sonnet` at complexity 3–6, `opus` at complexity 7–8) with the explorer's findings. Present its blueprint to the user briefly and get a go-ahead if the approach involves a non-obvious trade-off; otherwise proceed.
4. **Implement**: follow the blueprint, following codebase conventions strictly.
5. **Review**: launch one `task-reviewer` agent (model `opus`, per its default) scoped to the diff just produced. Fix Critical issues before reporting done; ask the user about Warnings.
6. **Report**: use the Phase Summary format below.

---

## Lane: `complex` (complexity 9–10, any task_type — at this score even a `specific-task`/`mcp-task` gets the full pipeline)

**Goal**: Handle genuinely large or architecturally significant work with the depth it needs.

**Actions**:
1. **Discovery**: confirm scope with the user if anything beyond the triage classification is still unclear.
2. **Exploration**: launch 2-3 `task-explorer` agents in parallel (model `sonnet`), each targeting a different aspect (similar past work, architectural understanding, user-facing behavior, MCP/integration surface if relevant). Read all files they flag as essential.
3. **Clarifying questions**: identify every remaining ambiguity — edge cases, error handling, integration points, scope boundaries, backward compatibility, performance needs. Present them all to the user in one organized list and wait for answers. Do not skip this phase.
4. **Architecture**: launch 2-3 `task-architect` agents in parallel (model `opus`), each with a different focus (minimal change, clean architecture, pragmatic balance). Compare trade-offs, form a recommendation, and ask the user which approach they prefer.
5. **Implementation**: on explicit user approval only. Implement following the chosen architecture and codebase conventions. For any single step that is itself unusually high-risk (e.g. a schema migration, an auth change), consider delegating just that step to an `opus`-model agent even though the surrounding implementation runs on the inherited model.
6. **Review**: launch 3 `task-reviewer` agents in parallel (model `opus`), each with a different focus (simplicity/DRY, bugs/correctness, project conventions). Consolidate findings, present to the user, and address based on their decision.
7. **Report**: use the Phase Summary format below.

---

## Phase Summary (for `standard` and `complex` lanes)

```markdown
## Smart Task complete
[1–3 sentences]

### JEV Triage
task_type: ... | complexity_score: .../10 | lane: ... | model tier: ...

### Files changed
| File | Change |
|------|--------|

### Verification
- Build/typecheck: ✅ or ❌ (if applicable)
- Lint: ✅ or ❌ (if applicable)

### Review result: Pass / Pass with notes / Needs changes

#### Critical (fixed / pending)
#### Warning
#### Suggestion

### Suggested next steps
```

After reporting, ask about deferred warnings if any, and — per this project's standard workflow — ask explicitly about commit and push as two separate decisions. Never commit or push without explicit confirmation in this session.
