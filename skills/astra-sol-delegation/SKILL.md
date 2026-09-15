---
name: astra-sol-delegation
description: "Delegate implementation, debugging, tests, and exploration from GPT-6 Astra to GPT-5.6 Sol in Codex, with task-appropriate effort. Skip in other-model sessions."
license: "MIT; see LICENSE.txt"
---

# Astra → Sol Delegation

Adapted from [steipete/agent-scripts' Codex First](https://github.com/steipete/agent-scripts/tree/main/skills/codex-first) for Codex-native orchestration.

Apply when the active parent model is GPT-6 Astra (`gpt-6-astra`). Delegate to GPT-5.6 Sol (`gpt-5.6-sol`) where doing so helps; Astra decides the scope and effort. If the active model is unknown, establish it from session metadata before applying this routing. Sol workers execute their assigned work directly and do not recursively invoke this skill. Model access and delegation support are prerequisites; this skill does not enable them. If Sol is unavailable, report the limitation and continue in Astra when feasible; do not silently substitute another worker model.

## Route

Prefer Sol for substantial, bounded hands-on work:

- Implementation from an agreed spec, refactors, and mechanical migrations.
- Bug fixes, test writing, CI fixes, dependency updates, and scripts.
- Focused codebase exploration with a clear question and useful summary.

Keep in Astra:

- Design, architecture, API and UX decisions, and unresolved requirements.
- Tiny changes where delegation overhead exceeds the work.
- Work requiring tools, credentials, or context unavailable to the worker.
- Destructive operations, releases, pushes, and external mutations, under the user's existing authorization and repository rules.
- Final review, integration, and verification of Sol's output.

For mixed tasks, settle the design and delegate a concrete work order. Do not force delegation when defining the work order would itself require solving the task. Delegation does not expand the user's scope or the worker's permissions.

## Choose reasoning effort

Astra chooses effort separately for each assignment. Use values supported by the active tool and model. Start with the ordinary reasoning levels below; availability varies by Codex version and account.

| Effort | Suitable work |
| --- | --- |
| `low` | Mechanical edits, renames, formatting, boilerplate, and straightforward dependency bumps. |
| `medium` | Routine implementation from a clear spec, tests for known behavior, and fixes with a known cause. |
| `high` | Multi-file features, shared abstractions, unknown-cause debugging, or interacting constraints. Default when uncertain. |
| `xhigh` | Difficult concurrency, algorithms, performance investigations, or subtle correctness requirements. |
| `max` (if supported) | Exceptional reasoning difficulty where Astra expects the extra effort and latency to help. |

Do not select a mode that automatically delegates further when the worker must work directly. Choose for reasoning difficulty, not merely output size. On a failed attempt, clarify the missing requirement or evidence and consider increasing effort. After two failed correction rounds, take over directly. Briefly state the delegated scope and chosen effort to the user.

## Delegate through native subagents

Prefer the available Codex collaboration tools. This skill requests delegation for suitable subtasks; obey the active tool's constraints on parallel work, context inheritance, model overrides, and concurrency limits.

With the `collaboration.spawn_agent` interface, explicitly set the worker model and effort, and use a fresh context so a full-history fork does not inherit Astra:

```json
{
  "task_name": "implement_subtask",
  "model": "gpt-5.6-sol",
  "reasoning_effort": "medium",
  "fork_turns": "none",
  "message": "Implement the specified subtask. Include the full work order described below. Work directly; do not delegate further."
}
```

Replace the illustrative name, effort, and message with the actual assignment. Spawn only a concrete, independent subtask while Astra has useful work to do alongside it. Workers share the filesystem: assign disjoint file ownership or isolated checkouts, preserve existing changes, and keep edits to overlapping files sequential.

Continue useful parent work, then collect results through the available collaboration completion or wait mechanism. Reuse the same worker for corrections with the follow-up tool. Do not create sidebar tasks unless the user explicitly requests a separate task.

## CLI fallback

If native delegation is unavailable or cannot handle the assignment, use Codex CLI only when permitted by the active environment. Check local `codex exec --help` before relying on options. Pin Sol, effort, and standard speed; preserve applicable execution restrictions. Do not bypass a tool restriction or rejected approval through the CLI.

Write the actual work order to a unique temporary file using a quoted heredoc or a file tool. Use task-specific variables and output paths. For a workspace-write assignment, the invocation is:

```bash
command codex exec -C "$sol_repo" \
  -m gpt-5.6-sol \
  -c model_reasoning_effort="$sol_effort" \
  --disable fast_mode -c 'service_tier="default"' \
  --sandbox workspace-write \
  -o "$sol_result" - < "$sol_prompt"
```

Set the variables to the exact repository, chosen effort, and unique prompt/result files first. Use `read-only` for exploration; add `--skip-git-repo-check` only outside a Git repository. Keep failure diagnostics available. Use the command tool's background/session mechanism for long runs and read the result after successful completion; quiet output alone does not mean a hang.

For corrections, resume the exact worker session ID, never an ambiguous `--last` when concurrent sessions exist. Check `codex exec resume --help`, run from the correct repository, retain its restrictions, and explicitly pin Sol, the chosen effort, and standard speed again. If the worker session cannot be identified, send a new self-contained work order instead.

## Work-order contract

Every worker starts with enough context to act independently:

- Goal, frozen design decisions, and acceptance criteria.
- Exact repository, relevant paths, and files the worker may edit.
- Constraints, non-goals, relevant repository instructions, and existing changes to preserve.
- Known evidence, reproduction details, and focused validation commands when applicable.
- Expected output: files changed or findings with paths, validation results, and unresolved issues.
- Instruction to work directly without further delegation.

Never include secrets merely to compensate for missing worker access. Give Sol the context it needs without copying the entire conversation.

## Verify in Astra

- Inspect the final changes and repository status; account for pre-existing user edits.
- Review correctness, scope, and integration yourself. A worker's summary is evidence to inspect, not proof by itself.
- Inspect meaningful test output or run the relevant checks. Avoid repeating successful checks without a reason.
- Correct or integrate the result, and apply the repository's normal review and delivery requirements.
- Report the outcome, validation, and material limitations concisely.

The aim is to move useful implementation and exploration work to Sol while Astra spends its attention on decisions and verification. Avoid trivia-sized assignments and unnecessary handoffs.
