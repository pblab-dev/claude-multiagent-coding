# Task Taxonomy (`task_type`)

## feature

A new capability that does not exist yet. Usually multi-file, may require new abstractions.
Examples: "add dark mode support", "add pagination to the users API".

## bugfix

A defect in existing behavior with a known or discoverable root cause.
Examples: "the export button crashes on empty lists", "fix the race condition in the queue worker".

## refactor

No behavior change; restructuring for clarity, performance, or maintainability.
Examples: "extract this into a hook", "split this 2000-line file".

## specific-task

A narrow, well-defined, mechanical-ish request with little ambiguity, whether or not it touches code. The defining trait is scope clarity, not size.
Examples: "rename X to Y across the repo", "write a script that converts CSV to JSON", "add a field Z to this schema".

## mcp-task

A request whose primary work happens through one or more MCP tools against an external system (Trello, Gmail, Search Console, a database, etc.), where local code changes are secondary or absent.
Examples: "create a Trello card for this bug", "check indexing issues for this URL in Search Console", "draft this email in Gmail".

`mcp-task` and `specific-task` are not mutually exclusive with `feature`/`bugfix`/`refactor` — when a task is genuinely both (e.g. "build a feature that syncs Trello cards on deploy"), classify by what dominates the effort. If the MCP interaction is incidental to a larger feature build, classify as `feature` and let `needs_mcp` stay true.

## research

Investigation, explanation, or read-only analysis with no implementation expected.
Examples: "how does the auth middleware work?", "what would break if we upgraded X?".

`research` tasks always route through the `quick` or `specific-mcp` lane (never `standard`/`complex`) regardless of `complexity_score`, since there is no implementation phase — only exploration and a written answer.
