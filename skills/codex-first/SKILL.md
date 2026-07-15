---
name: codex-first
description: "Route implementation work to Codex CLI; Claude specs, reviews, verifies."
---

# Codex First

Claude Code sessions only. Codex/other harnesses: skip; never self-delegate.

Rationale: Claude (Fable/Opus) tokens metered + expensive; Codex flat-rate. GPT-5.5+ is usually the better and faster model at writing/implementing code; Claude wins at ergonomics — judgment, design, spec-writing, review, orchestration. So Codex types, Claude thinks and verifies.

## Route

Delegate to Codex (default for hands-on work):

- implementation from a frozen spec; refactors; mechanical migrations
- bug fixes with known repro; test writing; coverage fills
- CI fixes, dependency bumps, scripts/tooling
- bulk codebase exploration where raw reading ≫ the answer

Keep in Claude:

- design, API design, architecture, naming, UX judgment
- tasks where writing the spec IS the work (ambiguity = design)
- tiny edits (~<20 lines, single obvious change) — delegation overhead loses
- anything needing session tools: MCP (browser/computer-use/chronicle), 1Password, secrets
- destructive/irreversible ops, releases, pushes, GitHub mutations — Claude-side per git rules
- review of Codex output — never delegated, never skipped

Mixed task: Claude designs first, freezes spec, delegates build-out.
Heuristic: prompt reads as a work order → delegate; writing it forces decisions → design, Claude.
Portfolio/multi-repo work: `$maintainer-orchestrator` instead.

## Invoke

Prompt via temp file, never inline quoting:

```bash
P=$(mktemp); cat >"$P" <<'EOF'
<goal, repo + key paths, constraints ("don't touch X"), non-goals, proof expected, output shape>
EOF
command codex exec --yolo -C <repo> \
  -m gpt-5.6-sol \
  -c model_reasoning_effort="high" \
  --enable fast_mode \
  -o /tmp/codex-last.md - <"$P" 2>/dev/null
```

- Model default: `gpt-5.6-sol`, effort `high`, fast mode on — pin all three explicitly; don't rely on user config.
- `--yolo` is the house default; Codex may run commands/tests freely. Keep prompts scoped to the target repo.
- `command codex` bypasses any interactive shell alias. If codex isn't on PATH, it depends on how it was installed:
  - node/standalone install: `fnm exec --using default -- codex` (a package-manager symlink or shim on PATH is fine — this caveat is only about the app bundle below).
  - ChatGPT desktop app (Codex merged into it, July 2026): the CLI ships bundled at `/Applications/ChatGPT.app/Contents/Resources/codex` and shares the app's ChatGPT sign-in. Expose **that** binary with an **exec-wrapper, not a symlink** — it locates sibling helpers (e.g. `codex-code-mode-host`) relative to its own invocation path, so a symlink to it misresolves them and `exec` dies with `the workspace execution host is missing` (the agent runs, but every file edit fails). Non-destructive wrapper (won't clobber an existing launcher):
    ```sh
    mkdir -p ~/.local/bin
    [ -e ~/.local/bin/codex ] || { printf '#!/bin/sh\nexec "/Applications/ChatGPT.app/Contents/Resources/codex" "$@"\n' > ~/.local/bin/codex && chmod +x ~/.local/bin/codex; }
    ```
    Or install the self-contained CLI via `curl -fsSL https://chatgpt.com/codex/install.sh | sh`, which needs no wrapper.
- stderr suppressed (thinking noise bloats context); drop `2>/dev/null` only to debug a failing run
- read `-o` file for the result; don't parse the JSONL stream
- long runs: Bash run_in_background, read `-o` file on exit; don't kill quiet runs <30 min
- parallel independent tasks OK: separate repos/dirs, separate `-o` files
- outside a git repo add `--skip-git-repo-check`

Follow-up fixes — cheaper than fresh runs, keeps context. `resume` has no `-C`/`--yolo`: run from the repo dir, spell the long flag:

```bash
(cd <repo> && command codex exec resume --last \
  --dangerously-bypass-approvals-and-sandbox \
  -o /tmp/codex-last.md - <"$P2" 2>/dev/null)
```

## Prompt contract

Codex starts with zero session context. Every prompt: goal, exact repo/paths, constraints, non-goals, proof expected (exact test command), output shape ("report files changed + test output"). Spec quality decides success.

## Verify (Claude, always)

- `git status -sb` + read the full diff; judge like a contributor PR
- run focused tests yourself or demand proof output; Codex claims are advisory
- iterate via resume; after 2 failed rounds, take over and do it directly
- normal closeout still applies: `$autoreview` before ship

## Economics

Win = generation + exploration tokens moved to Codex; Claude spends only on spec + diff review. Don't ping-pong trivia through delegation; don't re-read what Codex already summarized.
