---
name: JEV Decision Model
description: This skill should be used when the user asks to "classify this task", "decide which model to use", "route this task", "run JEV triage", "how complex is this task", or when the /smart-task command needs to determine task type, complexity, and which model tier (Haiku/Sonnet/Opus) and pipeline depth to use before starting work.
version: 0.1.0
---

# JEV Decision Model

## Overview

This skill defines a structured, typed decision layer inspired by JEV-class "decision models" (small, fast models that return bounded, typed decisions instead of free-form generation — see the TypeSafe AI Jev announcement for the pattern this is modeled on). TypeSafe's own Jev is a paid, hosted, closed-source service, but the pattern itself — Noul (yes/no), Escolha (selection), Pontuação (scored evaluation) — has a real open-source implementation in [OpenJev](https://github.com/SiliconLabAI/OpenJev). This plugin supports both: an optional external decision layer (OpenJev server, or a direct Groq call replicating its contract) with automatic fallback to Claude itself as the decision layer when neither is configured. See `references/decision-primitives.md` for the exact wiring.

Its job is to answer one question before any real work starts: **how much effort does this task deserve, and which model should do each part of it?** Under-provisioning wastes time re-doing shallow work; over-provisioning wastes tokens and money running a full multi-agent pipeline on a one-line fix.

## When to use this skill

Load this skill whenever a triage decision is needed before executing a task — most directly, at the start of the `/smart-task` command, but also any time a task's scope or model choice needs to be decided explicitly.

## Core procedure

1. **Classify** the request using the three primitives. First attempt the external decision layer (`scripts/jev-decide.sh` — see `references/decision-primitives.md` for how it's wired and when it's skipped); fall back to classifying with Claude itself when no external layer is configured or it fails. Full primitive definitions and the output JSON contract are in `references/decision-primitives.md`:
   - `task_type` (Escolha): `feature` | `bugfix` | `refactor` | `specific-task` | `mcp-task` | `research` — see `references/task-taxonomy.md` for what distinguishes each.
   - `complexity_score` (Pontuação): 0–10, scored against concrete criteria (files touched, design decisions required, integration points, ambiguity, blast radius).
   - `needs_clarification`, `needs_mcp`, `needs_multiagent` (Noul): each a `{value, confidence}` pair.

2. **Route** the classification to a lane and model tier using the tables in `references/model-routing.md`. The four lanes are:
   - `quick` — main thread executes directly, no sub-agents, no model override.
   - `specific-mcp` — one focused agent (or direct execution), model scales with score.
   - `standard` — one explorer + one architect + one reviewer, mostly Sonnet, Opus for architecture at higher scores.
   - `complex` — full parallel multi-agent pipeline (2–3 explorers, 2–3 architects, 3 reviewers), Opus for architecture and at least one review pass.

3. **Surface real ambiguity before proceeding.** If `needs_clarification.value` is true — including when it was forced true because its own confidence was below 0.6 — ask the user via `AskUserQuestion` rather than guessing; never silently pick a lane when the request is genuinely ambiguous. A low-confidence `needs_mcp` or `needs_multiagent`, by contrast, just resolves to `true` (provision more effort) without needing to interrupt the user.

4. **Emit the decision as a single structured block** (the JSON contract in `references/decision-primitives.md`) before starting the chosen lane. This keeps the routing decision auditable — the user can see *why* a task got the effort level it got.

## Design principle: decide small, execute big

The decision itself should be cheap and fast (Haiku-tier), even when the resulting work is expensive (Opus-tier, multi-agent). Never let the triage step itself balloon into a deep investigation — if classifying the task turns out to require deep codebase exploration, that is itself a signal of higher `complexity_score`, not a reason to keep triaging longer. Cap triage effort and let the routed lane do the deep work.

## Additional Resources

### Reference Files

- **`references/decision-primitives.md`** — Full definitions of Noul/Escolha/Pontuação and the exact output JSON schema.
- **`references/task-taxonomy.md`** — Definitions and examples for each `task_type` value.
- **`references/model-routing.md`** — Complexity → lane and lane → model tier tables, plus the rationale for running triage on the fastest model.

Used by the `jev-triage` agent (`agents/jev-triage.md`) and the `/smart-task` command (`commands/smart-task.md`) in this plugin.
