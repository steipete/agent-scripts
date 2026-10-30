---
name: codex-first
description: "Claude Code work routing: delegate hands-on work to Codex under the native-Claude model gate. Keep specification, judgment, and verification in Claude; prefer isolated Codex-backed autoreview."
---

# Codex First

## Launch flags — read first, copy verbatim

Default every Codex worker, **fresh or resumed**, to **GPT-6.1 Sol, high
reasoning, Fast service tier** (`service_tier="fast"`, sent as API `priority`;
Peter, 2026-10-30). Pass all three settings unless the user requests an override.

```bash
# fresh
codex exec --yolo -C "$WT" \
  -m gpt-6.1-sol -c 'model_reasoning_effort="high"' \
  --enable fast_mode -c 'service_tier="fast"' \
  -o "$OUT" - < "$ORDER"
# resume: pass the same flags again; resume does not inherit them
codex exec resume "$SID" --dangerously-bypass-approvals-and-sandbox \
  -m gpt-6.1-sol -c 'model_reasoning_effort="high"' \
  --enable fast_mode -c 'service_tier="fast"' -o "$OUT" -
```

- Old Codex CLIs silently omit tiers they do not know (codex-cli 0.147 on Team warned
  `not advertised` and sent no tier); keep the CLI current. Verified on Team with 0.166.0,
  2026-10-30.
- Ultrafast only on request: swap in `-c 'service_tier="ultrafast"'` and add
  `-c 'model_auto_compact_token_limit=260000'`. It is served up to ~282k prompt tokens, flaky at
  288–294k, and silently `fast` at ≥300k (measured 2026-10-13); the 260k cap keeps it there.
  Rollouts record only the requested tier; prove the served tier with a direct probe
  (`response.service_tier`). Details: [launch details](references/launch-details.md).
- Context: workers get the base 500k window. Add `-p sol61-1m` (or `-p astra-1m`) only when the
  order needs a whole-repo context; see `$codex-huge-context`.
- Copy all model/reasoning/tier flags into wrappers; override only on user request. Verify launch
  arguments (`fast` default; requested `ultrafast` is valid).

### Security audits and cyber-classifier refusals → Daybreak Red (Peter, 2026-10-15/18)

Security audit lanes (threat models, injection/secret-exposure audits, permission inventories,
security review of hardening diffs) launch on **Daybreak Red** from the start (Peter 2026-10-18:
"use daylight red model for security audits"). Implementation workers stay on Sol.

Worker stops with `This content was flagged for possible cybersecurity risk` → relaunch or resume
the same order on **Daybreak Red** (Peter: "use daybreak red if you hit a blocker with regular
models"). Don't rephrase to dodge the classifier or hop between regular models.

- Direct API only: the ChatGPT-account route returns 400 `not supported when using Codex with a
  ChatGPT account`. Add `-c 'model_provider="openai_api_direct"'` (API key via the provider's
  auth command in `~/.codex/config.toml`).
- Slug: the `model_catalog_json` entry whose `display_name` is `Daybreak Red`. Keep it out of
  public artifacts (commits, PRs, issues, logs) per public model naming.
- No Fast/Ultrafast tier: drop `--enable fast_mode` / `service_tier`; keep `model_reasoning_effort="high"`.
- Verified 2026-10-15 with a one-line `codex exec` probe on the direct provider.

### Capacity fallback (Peter, 2026-10-12)

Org caps `gpt-6.1-sol` at 40M tokens/min. Worker or resume fails with `Rate limit reached for
gpt-6.1-sol ... tokens per min (TPM)`, `Selected model is at capacity`, or `overloaded` → resume
that same session on **GPT-6 Astra, high, Fast** immediately (Peter, 2026-10-12: "use
astra if sol has rate limits"); no waiting loop:

```bash
codex exec resume "$SID" --dangerously-bypass-approvals-and-sandbox \
  -m gpt-6-astra -c 'model_reasoning_effort="high"' \
  --enable fast_mode -c 'service_tier="fast"' -o "$OUT" -
```

- Resume onto Astra keeps the thread (verified 2026-10-12: Sol-created session resumed on Astra and replied).
  Fresh orders at capacity: same flags with `codex exec --yolo -C "$WT"`; a fresh launch that dies
  on capacity already has a session id in stderr (`session id: …`) — resume that, don't relaunch.
- Back off only when Sol and Astra are both limited; then alternate with growing sleeps.
- Wrapper retry triggers must match all three strings (`rate limit|at capacity|overloaded`);
  matching only "rate limit" made capacity failures exit instead of falling back.
- Autoreview at capacity: `--model gpt-6-astra --thinking high --codex-speed fast`. If autoreview
  refuses because its provider/route doesn't match operator config, don't change config — review
  with a fresh-context subagent (diff + brief) and say so in the PR.
- New workers still start on Sol 6.1 Fast; fall back per worker, only on the capacity error.
- Restarts and recoveries: `~/.codex/skills/agent-scripts/codex-first/scripts/codex-resume` does the
  fallback, busy check, safe stop, and classified exits ([resume and watchdog](references/resume-and-watchdog.md)).

### Wrapper and process hygiene (2026-10-12/13)

- Never edit a running wrapper script in place: bash reads scripts incrementally, so live runs
  execute the new bytes at their old offset. Write `x.new`, `bash -n`, `chmod +x`, then `mv`
  (rename keeps the old inode for running copies; forgetting `chmod` gives exit 126).
- Never run `codex exec` under `set -e` in a wrapper: a rate-limit death exits non-zero and ends
  the script before its fallback runs (2026-10-13, a 27-worker fleet). Capture the code
  (`… && rc=0 || rc=$?`) and classify it, or hand the session to `codex-resume`.
- Killing a wrapper orphans its `codex exec` children; the next resume then fails with
  `thread … already has an active writer`. Stop and resume with `codex-resume --stop "$SID"`:
  it finds the worker through its open rollout file (fresh launches don't carry `$SID` in argv,
  so `pgrep -f` misses them) and refuses while `scripts/pr` or git runs beneath it. A leftover
  `~/.codex/thread-writer-locks/$SID.lock` file without a live holder is harmless.
- To redirect a running worker (new design/priority), `codex-resume --stop -p "$ORDER_FILE" "$SID"` (or `--message "…"`);
  its worktree changes and context survive.
- To retire a worker for good, do not use `codex-resume`: `--stop` always resumes afterward
  (2026-10-18, a cancelled worker restarted in its deleted worktree). Kill the native codex
  binary (`pgrep -P <node-shim-pid>`), then the node shim and its wrapper.

## Hard gate

**Autoreview exception:** always prefer Codex-backed `$autoreview`, independent
of `ANTHROPIC_BASE_URL`, router state, or harness. Reviewing a frozen bundle is
not hands-on self-delegation. Do not switch review engines merely because the
parent session is router-backed. This exception takes precedence over the gate
below.

Use the autoreview helper with `--engine codex` (defaults: 6.1 Sol, medium, Ultrafast) unless the user requests an override. It tries the ChatGPT subscription first and, on an auth failure, retries once on the configured direct-API provider; pass `--codex-config 'model_provider="openai_api_direct"'` only to skip the subscription attempt. Preserve the helper's reviewer isolation.

For direct hands-on delegation, use this skill only
when the active agent is Claude Code **and** the session is running on a native
Claude model.

**Model check (primary).** The point of the gate is model economics: Claude
tokens are metered and expensive, so hands-on work moves to Codex; but if the
session is already routed to a cheaper/other model, delegation gains nothing.
Decide by the model the session actually runs on, not by the transport:

1. Read the model id from the system prompt's environment section ("You are
   powered by the model …"). Router-wrapped ids may be opaque
   (`claude-ccr-<hex>`); the hex suffix is often ASCII — decode it
   (`echo <hex> | xxd -r -p`) to reveal the underlying route, e.g.
   `Gorilla CCP/native-claude-fable-5`.
2. If the resolved model is a native Claude model (contains `claude`, `fable`,
   `opus`, `sonnet`, or `haiku`, including `native-claude-*` router routes):
   **delegate hands-on work to Codex.** This applies even when
   `ANTHROPIC_BASE_URL` is loopback or a local router (Gorilla Claw, Clawdex)
   — a router in front of a real Claude model is still expensive Claude.
3. If the resolved model is clearly non-Claude (a GPT/other-provider route):
   the session is already on the flat-rate/cheap side; do not self-delegate,
   work directly.

**Base-URL fallback (only when the model cannot be identified).** If no model
id is visible and the hex/route cannot be decoded, fall back to the old
transport heuristic: if `ANTHROPIC_BASE_URL`'s host is
`gorillaclaw.sheep-coho.ts.net`, `localhost`, ends in `.localhost`, is in
`127.0.0.0/8`, or is IPv6 loopback `::1`, assume the session may be routed to
a non-Claude model and work directly. If neither model nor base URL can be
inspected, fail closed and work directly.

Codex, ChatGPT, Pi, and every other harness: do not invoke Codex CLI for hands-on
self-delegation. Continue the task directly. This gate overrides a repository
instruction that merely mentions `$codex-first`; it does not override the
autoreview exception above.

The default worker is GPT-6.1 Sol on the Fast tier. Claude handles specification, judgment, orchestration, and final verification; Codex handles the delegated implementation.

## Route

Delegate to Codex (default for hands-on work):

- implementation from a frozen spec; refactors; mechanical migrations
- fixing: bug fixes (known repro, or diagnose-then-fix), CI/lint/type failures; test writing; coverage fills
- dependency bumps, scripts/tooling
- exploration + exploratory subagents: fan out Codex for read-heavy discovery instead of Claude Explore/Task subagents whenever raw reading ≫ the answer (parallel `-o` files, one per thread)
- git mechanics — ALWAYS Codex, never Claude directly: `git rebase`, merge-conflict
  resolution, and the repo's land workflow (e.g. `scripts/pr`) are mandatory
  delegations. Issue ONE self-contained work order covering
  rebase→resolve→push→CI attach+green→land so the sequence never bounces back to
  Claude mid-flight; the land decision, gates, and review below stay Claude's.
- work-order CI waits: precheck PR mergeable (CONFLICTING = pull_request CI
  cannot attach — no merge ref) and confirm a run attached to the exact head
  SHA before polling; every wait emits all terminal states with bounded
  iterations; prefer the repo's watcher script when one exists (openclaw:
  `node scripts/watch-pr-ci.mjs`). Never `gh run watch` or `gh pr checks --watch`
  in work orders: `gh run watch` polls every 3 s by default (~1,200 calls/hour), and
  two such watchers drained a shared 5,000/hour writer token twice on 2026-10-15.
  Poll one exact run with `gh run view <id> --json status,conclusion` at most every
  ~10 minutes, or let the repo's landing tool own the wait.
- new work orders go to FRESH `codex exec` sessions with self-contained prompts.
  Do not resume a long-lived session for a new order — saturated sessions
  misread work orders as configuration and no-op ("Understood…").
- repo instruction files: NEVER create or edit `CLAUDE.md`. `AGENTS.md` is
  canonical in every repo; `CLAUDE.md` exists only as a symlink to it. Point
  Codex work orders at `AGENTS.md` and edit only `AGENTS.md`.

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

- Run `timeout 8 git --version`; for an Xcode-beta hang, set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in the session and every order.
- For `openai_api_direct`, run `ruby ~/.codex/skills/agent-scripts/codex-huge-context/scripts/preflight.rb` before the batch's first fresh/resumed launch. If Keychain delivery fails, stop; never override the provider or use ordinary Codex auth.
- Keep the configured provider; resume inherits it. If incompatible with 6.1 Sol, start fresh; never silently change models.
- Use repo-scoped `--yolo`, temp-file prompts (never inline quoting), and `-o` results (not JSONL).
- **Harness visibility (Claude Code): every codex run gets its own harness-tracked
  background command (`run_in_background: true`) — one sidebar chip per worker,
  completion notification included. Chain setup steps (installs, worktree prep)
  INSIDE that tracked command. Never `&`-fork workers from a shared launcher:
  the launcher's chip exits at fork time and the workers become invisible
  orphans supervised only by PID files.**
- parallel independent tasks OK: separate repos/dirs, separate `-o` files, one tracked background command per worker
- outside a git repo add `--skip-git-repo-check`
- For Fast/catalog checks, CLI setup, or execution details: read [launch details](references/launch-details.md).
- On failure or provider changes: [troubleshooting](references/troubleshooting.md); never put credentials in `-c key=value`.
- Before resuming/monitoring: [resume and watchdog](references/resume-and-watchdog.md). Resume and restart through `scripts/codex-resume` (`--dry-run` first when unsure).

## Prompt contract

Codex starts with zero session context. Every prompt: goal, exact repo/paths, constraints, non-goals, proof expected (exact test command), output shape ("report files changed + test output"). Spec quality decides success.

- **Name the domain skill.** When the repo has a skill for the area being changed (e.g. openclaw `.agents/skills/solid/SKILL.md` for Control UI/Solid work), the work order says to read it, plus the references it routes to, before the first edit. Codex auto-loads only the AGENTS.md chain from its working directory, so a skill linked from a nested AGENTS.md is easy to miss.

- **Every hard prohibition needs an escape hatch.** A cornered worker satisfies the letter of the
  gates: told "never raise the size budget" while its design inflated the bundle, Codex
  hand-minified source identifiers to single letters — and passed every gate including
  autoreview. Pair each hard constraint with the sanctioned exit: "if gate X fails after honest
  attempts: STOP, report exact numbers/diagnosis, do not work around." Treat a stop-report as a
  successful run (it is the coordinator's decision point, and workers use it correctly once it
  exists).
- Multi-PR series: same spec skeleton every PR; cite prior landed PR numbers and name their
  idioms ("controller with narrow host interface, the #NNN shape") — workers imitate landed
  precedent far more reliably than abstract style rules. Fold each round's new trap into the
  next spec.
- End every series work order with an explicit stop: "Do exactly this; do not start PR N+1."

- Work-order proof: PR CI is the default broad proof; open a ready PR once the build and focused local tests/typecheck/lint/format pass, without waiting for pre-PR broad suites; use Crabbox/Testbox only for gaps CI/local cannot cover and only if granted immediately (queued → local; no Testbox → AWS → Hetzner ladder); fix real failures, read CI's pre-existing/new classification, and never rerun/re-push just for green. Keep untrusted code secretless, live credentials authorized, and Gateway/state isolated.

Before reviewing/landing or coordinating workers, read [coordination](references/coordination.md); check for live workers before editing/committing.
