#!/usr/bin/env bash
# jev-decide.sh — optional external JEV-style decision layer for the jev-triage agent.
#
# Picks exactly one backend, in this precedence order (not a fallback chain — if the chosen
# backend is configured but fails, this exits 1 rather than trying the next one; the caller,
# jev-triage, then falls back to classifying the task itself):
#   1. A real running OpenJev server (https://github.com/SiliconLabAI/OpenJev), if OPENJEV_URL is set.
#   2. A direct call to Groq's OpenAI-compatible API, if GROQ_API_KEY is set (and OPENJEV_URL is
#      not) — this replicates OpenJev's own "oneshot" backend prompt/response contract, so both
#      paths normalize to the same schema.
#   3. Neither configured → exit 1 with empty stdout.
#
# Usage:
#   jev-decide.sh <<'EOF'
#   <task request text, verbatim, unquoted — always via a quoted heredoc so the caller's shell
#   never expands backticks/$()/$VAR that may appear inside the request text>
#   EOF
#
# Env vars:
#   OPENJEV_URL   Base URL of a running OpenJev server, e.g. http://localhost:3001
#   GROQ_API_KEY  Groq API key (https://console.groq.com/keys)
#   GROQ_MODEL    Groq model id (default: llama-3.1-8b-instant)
#
# Output (stdout, on success): normalized JSON —
#   {"task_type": "...", "complexity_score": 0-10,
#    "needs_clarification": {"value": bool, "confidence": 0-1},
#    "needs_mcp": {"value": bool, "confidence": 0-1},
#    "needs_multiagent": {"value": bool, "confidence": 0-1},
#    "source": "openjev" | "groq-direct"}
# On any failure (backend unconfigured, unreachable, or a required field missing from its
# response): exit 1, empty stdout. A missing/invalid score is treated as failure, never as 0 —
# silently defaulting complexity to 0 would route a possibly-complex task into the cheapest lane.

TASK="$(cat)"
if [ -z "$TASK" ]; then
  echo "usage: jev-decide.sh <<'EOF' / <task request text> / EOF" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || exit 1
command -v curl >/dev/null 2>&1 || exit 1

# Score type uses an ordered array of level descriptions (OpenJev's ScoreQuestion.criteria: string[]).
# The returned score is a float index (0..3) across these 4 levels; we scale it to 0-10 downstream.
QUESTIONS='{
  "task_type": {
    "type": "choice",
    "instructions": "Which category best fits this development task?",
    "criteria": {
      "feature": "A new capability that does not exist yet",
      "bugfix": "A defect in existing behavior",
      "refactor": "Restructuring with no behavior change",
      "specific-task": "A narrow, well-defined, low-ambiguity request",
      "mcp-task": "Work centered on calling an external tool or MCP integration",
      "research": "Investigation or explanation only, no implementation expected"
    }
  },
  "complexity_band": {
    "type": "score",
    "instructions": "Rate the complexity of this task considering files/modules touched, design decisions required, integration points, ambiguity, and blast radius if implemented wrong.",
    "criteria": [
      "Trivial: single obvious change, no real design decision",
      "Simples-moderada: poucos arquivos, baixa ambiguidade",
      "Moderada-alta: multiplos modulos, pontos de integracao reais",
      "Alta: nova arquitetura, alta ambiguidade, amplo raio de impacto"
    ]
  },
  "needs_clarification": {
    "type": "noul",
    "instructions": "Does the request contain a real ambiguity that blocks safe execution?"
  },
  "needs_mcp": {
    "type": "noul",
    "instructions": "Is an external tool or MCP integration central to completing this task (not just incidental)?"
  },
  "needs_multiagent": {
    "type": "noul",
    "instructions": "Does the scope justify a parallel explore/design/review pipeline rather than direct execution?"
  }
}'

# Shared normalization: $band is a raw score in the 0..3 level-index space. Any missing/non-numeric
# band, or a value clearly outside that space (a model anchoring on 0-10 instead of the 4 levels it
# was given), is treated as a hard failure rather than silently coerced.
NORMALIZE='
  def noulFlag(n): if (n|type) != "number" then error("missing noul") else
    {value: (n > 0.5), confidence: (if n > 0.5 then n else 1 - n end)} end;
  def bandToScore(b): if (b|type) != "number" or b < 0 or b > 3 then error("missing/invalid score") else
    ([(b / 3 * 10 | round), 10] | min) end;
'

# --- Path 1: real OpenJev server -------------------------------------------------------------
if [ -n "${OPENJEV_URL:-}" ]; then
  PAYLOAD=$(jq -n --arg state "$TASK" --argjson questions "$QUESTIONS" '{state: $state, questions: $questions}') || exit 1
  RESPONSE=$(curl -sS --max-time 15 -X POST "${OPENJEV_URL%/}/api/evaluate" \
    -H "Content-Type: application/json" -d "$PAYLOAD") || exit 1

  echo "$RESPONSE" | jq -e "
    ${NORMALIZE}
    if .error then error(.error) else
    {
      task_type: .answers.task_type.choice,
      complexity_score: bandToScore(.answers.complexity_band.score),
      needs_clarification: noulFlag(.answers.needs_clarification.noul),
      needs_mcp: noulFlag(.answers.needs_mcp.noul),
      needs_multiagent: noulFlag(.answers.needs_multiagent.noul),
      source: \"openjev\"
    } end
  " 2>/dev/null && exit 0
  exit 1
fi

# --- Path 2: direct Groq call, replicating OpenJev's "oneshot" contract ----------------------
if [ -n "${GROQ_API_KEY:-}" ]; then
  MODEL="${GROQ_MODEL:-llama-3.1-8b-instant}"
  SYSTEM="You are a precise decision engine. Answer every question based only on the provided state. Return probabilities that reflect genuine uncertainty. Do not invent information."
  USER_MSG=$(cat <<EOF
STATE:
${TASK}

QUESTIONS:
- task_type (choice): Which category best fits this development task?
  Options -> feature: A new capability that does not exist yet, bugfix: A defect in existing behavior, refactor: Restructuring with no behavior change, specific-task: A narrow well-defined low-ambiguity request, mcp-task: Work centered on an external tool/MCP integration, research: Investigation or explanation only
- complexity_band (score): Rate complexity (files touched, design decisions, integration points, ambiguity, blast radius).
  Levels -> 0=Trivial: single obvious change | 1=Simples-moderada: poucos arquivos, baixa ambiguidade | 2=Moderada-alta: multiplos modulos, pontos de integracao reais | 3=Alta: nova arquitetura, alta ambiguidade, amplo raio de impacto
  Answer with the LEVEL INDEX (0, 1, 2 or 3) as "score" — never a 0-10 value.
- needs_clarification (noul): Does the request contain a real ambiguity that blocks safe execution?
- needs_mcp (noul): Is an external tool or MCP integration central to completing this task?
- needs_multiagent (noul): Does the scope justify a parallel explore/design/review pipeline rather than direct execution?

Respond with JSON. For choice: { "choice", "confidence" }. For score: { "score" (0-3 level index), "confidence" }. For noul: { "noul" (0-1 probability) }. Top-level keys = question names.
EOF
)
  BODY=$(jq -n --arg model "$MODEL" --arg system "$SYSTEM" --arg user "$USER_MSG" \
    '{model: $model, temperature: 0, response_format: {type: "json_object"},
      messages: [{role: "system", content: $system}, {role: "user", content: $user}]}') || exit 1

  # Header passed via a config file (process substitution) rather than -H on the command line,
  # so the API key never appears in this process's argv (visible to other local users via `ps`).
  RESPONSE=$(curl -sS --max-time 15 https://api.groq.com/openai/v1/chat/completions \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "${GROQ_API_KEY}") \
    -H "Content-Type: application/json" \
    -d "$BODY") || exit 1

  echo "$RESPONSE" | jq -e "
    ${NORMALIZE}
    (.choices[0].message.content | fromjson) as \$a |
    {
      task_type: \$a.task_type.choice,
      complexity_score: bandToScore(\$a.complexity_band.score),
      needs_clarification: noulFlag(\$a.needs_clarification.noul),
      needs_mcp: noulFlag(\$a.needs_mcp.noul),
      needs_multiagent: noulFlag(\$a.needs_multiagent.noul),
      source: \"groq-direct\"
    }
  " 2>/dev/null && exit 0
  exit 1
fi

# --- No external decision layer configured ---------------------------------------------------
exit 1
