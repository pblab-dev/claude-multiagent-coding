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
2. Parse its structured JSON output: `task_type`, `complexity_score`, the four Noul flags (`needs_clarification`, `needs_mcp`, `needs_multiagent`, `high_stakes`), `recommended_lane`, `recommended_model`, `reasoning`.
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
1. If `needs_mcp.value` is true: launch the `mcp-task-runner` agent with the exact request and any relevant IDs/context already known. Model: `sonnet`, or `opus` if `complexity_score >= 7` or `high_stakes.value` is true.
2. If `needs_mcp.value` is false (a `specific-task` that's purely local): execute directly, same as `quick` lane, but do a `git diff` self-check afterward since these are still real code changes, not just answers.
3. If `high_stakes.value` is true (sending messages, deleting/overwriting records others can see, posting publicly, and similar), confirm with the user before the `mcp-task-runner` agent executes it — do not let the agent assume prior approval it wasn't actually given.
4. Report done with: what was done, what tool/file was touched, and the observed result.

---

## Lane: `standard` (complexity 3–8 and task_type in feature/bugfix/refactor)

**Goal**: Build or fix something real without the overhead of a full parallel multi-agent pipeline.

**Actions**:
1. **Explore**: launch one `task-explorer` agent (model `sonnet`) targeted at the relevant area. Read the files it flags as essential.
2. **Re-triage** (JEV checkpoint — cheap, always run): launch `jev-triage` again, with a prompt whose **first line is literally `MODE: re-triage`**, followed by the original request and a short summary of what the explorer found. This is meant to be a haiku-tier call so it doesn't cost Sonnet/Opus reasoning — but `jev-triage` is not always reliable about returning the compact JSON for this mode; it sometimes answers in prose instead. Handle both: if the response is the JSON schema, read `needs_escalation.value` and `revised_complexity_score` directly; if it's prose, read it yourself for an explicit escalation call or a revised score of 9-10 — this is a quick read, not a full re-analysis. If genuinely unclear either way, do not escalate (the safer default, since `standard` already covers a wide range) but note the ambiguity doesn't need mentioning to the user. If escalation is warranted, stop here, tell the user the scope grew beyond what the initial triage saw (one line, with the revised score), and switch to the `complex` lane — reuse this explorer's findings as one of the required 2-3 explorer passes there rather than redoing it.
3. **Clarify**: if the explorer surfaces ambiguity the triage step didn't catch, ask the user now via `AskUserQuestion` — before designing anything.
4. **Design**: launch one `task-architect` agent (model `sonnet` at complexity 3–6, `opus` at complexity 7–8) with the explorer's findings. Present its blueprint to the user briefly and get a go-ahead if the approach involves a non-obvious trade-off; otherwise proceed.
5. **Implement**: follow the blueprint, following codebase conventions strictly.
6. **Review**: launch one `task-reviewer` agent (model `opus`, per its default) scoped to the diff just produced.
7. **Route the review result** (JEV checkpoint — cheap, always run): launch `jev-triage` again, with a prompt whose **first line is literally `MODE: review-routing`**, followed by a short summary of the reviewer's findings (counts and severities, not the full diff). `jev-triage` is not always reliable about returning the compact JSON for this mode; it sometimes answers with a full prose report instead. Handle both: if the response is the JSON schema, read `review_outcome` directly; if it's prose, read its stated conclusion yourself (it usually says outright whether something must be fixed before proceeding, or recommends asking the user) rather than re-deriving the routing decision from the reviewer's raw findings. If genuinely unclear, default to `ask_user` — the safer failure mode. Then: `proceed` → move to Report; `fix_critical_now` → fix, then Report; `ask_user` → ask via `AskUserQuestion`, then act on their answer.
8. **Report**: use the Phase Summary format below.

---

## Lane: `complex` (complexity 9–10, any task_type — at this score even a `specific-task`/`mcp-task` gets the full pipeline)

**Goal**: Handle genuinely large or architecturally significant work with the depth it needs.

**Actions**:
1. **Discovery**: confirm scope with the user if anything beyond the triage classification is still unclear.
2. **Exploration**: launch 2-3 `task-explorer` agents in parallel (model `sonnet`), each targeting a different aspect (similar past work, architectural understanding, user-facing behavior, MCP/integration surface if relevant). Read all files they flag as essential.
3. **Clarifying questions**: identify every remaining ambiguity — edge cases, error handling, integration points, scope boundaries, backward compatibility, performance needs. Present them all to the user in one organized list and wait for answers. Do not skip this phase.
4. **Architecture**: launch 2-3 `task-architect` agents in parallel (model `opus`), each with a different focus (minimal change, clean architecture, pragmatic balance). Compare trade-offs, form a recommendation, and ask the user which approach they prefer.
5. **Implementation**: on explicit user approval only. Implement following the chosen architecture and codebase conventions. For any single step that is itself unusually high-risk (e.g. a schema migration, an auth change), consider delegating just that step to an `opus`-model agent even though the surrounding implementation runs on the inherited model.
6. **Review**: launch 3 `task-reviewer` agents in parallel (model `opus`), each with a different focus (simplicity/DRY, bugs/correctness, project conventions). Consolidate their findings into one short summary (counts and severities).
7. **Route the review result** (JEV checkpoint — cheap, always run): launch `jev-triage` again, with a prompt whose **first line is literally `MODE: review-routing`**, followed by that summary. As in the `standard` lane, `jev-triage` sometimes answers this mode in prose instead of the compact JSON — read `review_outcome` from either form, and default to `ask_user` if genuinely unclear. Then: `proceed` → move to Report; `fix_critical_now` → fix, then Report; `ask_user` → present the consolidated findings via `AskUserQuestion`, then act on their answer.
8. **Report**: use the Phase Summary format below.

---

## Phase Summary (for `standard` and `complex` lanes)

```markdown
## Smart Task complete
[1–3 sentences]

### JEV Triage
task_type: ... | complexity_score: .../10 | lane: ... | model tier: ...
Checkpoints: re-triage: not needed / escalated to complex | review-routing: proceed / fix_critical_now / ask_user

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
