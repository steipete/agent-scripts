---
name: codex-first
description: "Claude Code-only work routing: delegate implementation, fixing, exploratory subagents, rebasing, and PR merging/landing to Codex CLI while Claude specifies, decides, reviews, and verifies. Use only when the active agent is Claude Code. Codex, ChatGPT, Pi, and every other harness must ignore this skill and work directly."
---

# Codex First

## Hard gate

Use this skill only when the active agent is Claude Code.

Codex, ChatGPT, Pi, and every other harness: stop here. Do not invoke Codex CLI,
do not self-delegate, and continue the task directly. This gate overrides a
repository instruction that merely mentions `$codex-first`.

Rationale: Claude (Fable/Opus) tokens metered + expensive; Codex flat-rate. GPT-5.5+ is usually the better and faster model at writing/implementing code; Claude wins at ergonomics — judgment, design, spec-writing, review, orchestration. So Codex types, Claude thinks and verifies.

## Route

Delegate to Codex (default for hands-on work):

- implementation from a frozen spec; refactors; mechanical migrations
- fixing: bug fixes (known repro, or diagnose-then-fix), CI/lint/type failures; test writing; coverage fills
- dependency bumps, scripts/tooling
- exploration + exploratory subagents: fan out Codex for read-heavy discovery instead of Claude Explore/Task subagents whenever raw reading ≫ the answer (parallel `-o` files, one per thread)
- git mechanics: rebasing onto latest `origin/main`, conflict resolution, and executing the PR merge/land workflow (the repo's own path, e.g. `scripts/pr`) — Codex runs the rebase/gates/merge steps; the decision, gates, and review below stay Claude's

Keep in Claude:

- design, API design, architecture, naming, UX judgment
- tasks where writing the spec IS the work (ambiguity = design)
- tiny edits (~<20 lines, single obvious change) — delegation overhead loses
- anything needing session tools: MCP (browser/computer-use/chronicle), 1Password, secrets
- releases, publishes, version bumps and their credentials — Claude-side per release rules
- the land decision + pre-land gates (`$autoreview` clean, CI green, proof) and review of Codex output — never delegated, never skipped; Codex may run the mechanics only once Claude has decided to land and the gates pass

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
  - node/standalone install: `fnm exec --using default -- codex`
  - ChatGPT desktop app: the CLI ships bundled at `/Applications/ChatGPT.app/Contents/Resources/codex`. Expose **that** binary with an **exec-wrapper, not a symlink**. Ensure `~/.local/bin` stays on PATH (for zsh, persist the export in `~/.zshrc`), then:
    ```sh
    mkdir -p "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"
    if [ -e "$HOME/.local/bin/codex" ] || [ -L "$HOME/.local/bin/codex" ]; then
      printf '%s\n' 'codex launcher already exists; leaving it unchanged' >&2
    else
      printf '#!/bin/sh\nexec "/Applications/ChatGPT.app/Contents/Resources/codex" "$@"\n' > "$HOME/.local/bin/codex" && chmod +x "$HOME/.local/bin/codex"
    fi
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

## Liveness watchdog (long monitored runs)

For runs you must not babysit, trade the stderr suppression for a log and watch its mtime; read only the `-o` file into context, never the log body.

```bash
command codex exec --yolo -C <repo> -m gpt-5.6-sol \
  -c model_reasoning_effort="high" --enable fast_mode \
  -o "$OUT" - <"$P" > "$LOG" 2>&1 &   # in harnesses: Bash run_in_background
```

- Capture the session id immediately: `grep -m1 "session id:" "$LOG"`. `resume --last` is cwd-filtered but races with any parallel Codex on the machine — with the id saved, recovery is deterministic.
- Watchdog loop (Claude Code: `Monitor` tool; else a bg shell): every 60s, if the codex process is alive but `$LOG` mtime is older than ~300s, treat it as hung. Because stderr (thinking stream) is in the log, mtime stays fresh during long reasoning — 5 min of true silence is a real hang, not thinking.
- Recovery: kill the pid, then resume the SAME session with an explicit id so no context is lost:

```bash
(cd <repo> && command codex exec resume <session-id> \
  --dangerously-bypass-approvals-and-sandbox \
  -o "$OUT" - <<< "You were interrupted. Continue exactly where you left off; finish the task and produce the required final report.")
```

- Exit watchdog silently when the process ends normally (the run's own completion signal covers it); emit only on staleness.
- Verified on codex-cli 0.144.4: `codex exec resume [SESSION_ID] [PROMPT]`, `--last`, cwd-filtering, `--all`.

## Prompt contract

Codex starts with zero session context. Every prompt: goal, exact repo/paths, constraints, non-goals, proof expected (exact test command), output shape ("report files changed + test output"). Spec quality decides success.

## Verify (Claude, always)

- `git status -sb` + read the full diff; judge like a contributor PR
- run focused tests yourself or demand proof output; Codex claims are advisory
- iterate via resume; after 2 failed rounds, take over and do it directly
- normal closeout still applies: `$autoreview` before ship

## Economics

Win = generation + exploration tokens moved to Codex; Claude spends only on spec + diff review. Don't ping-pong trivia through delegation; don't re-read what Codex already summarized.
