# Resume and monitored runs

Read before resuming a follow-up or starting a monitored run. New work orders always use fresh sessions.

## Robust restart: `scripts/codex-resume`

Use the script for every restart, follow-up resume, or rate-limit recovery instead of hand-rolled
`codex exec resume` lines. Run it as its own harness-tracked background command.

```bash
R=<this skill>/scripts/codex-resume   # e.g. ~/.claude/skills/codex-first/scripts/codex-resume
$R --dry-run "$SID"                                 # resolved cwd, live pid, exact command
$R -p "$DELTA_FILE" -o "$OUT" "$SID"                # follow-up from a file (--message "…" inline)
$R -o "$OUT" "$LOG"                                 # session id read from the fresh run's log
$R --stop -o "$OUT" "$SID"                          # close a live/hung worker, then resume
$R --model gpt-6-astra --tier fast -o "$OUT" "$SID" # start on the fallback while Sol is limited
```

It owns the traps below so wrappers don't have to:

- **Same session, right place.** Finds the rollout under `$CODEX_HOME/sessions`, resumes from the
  cwd recorded in its `session_meta` (resume has no `-C`), and re-passes model, reasoning, tier, and `-o`.
- **Busy check.** A live codex keeps its rollout file open, so `lsof` on it identifies the exact
  worker, whether it started fresh or resumed. Without `--stop` a live session exits 4 instead of
  forking a second writer. `--stop` sends INT, then TERM, then KILL, only to the processes that hold
  the rollout, and waits until the file is released.
- **Never mid-landing.** `--stop` refuses (exit 5) while a descendant runs `scripts/pr`,
  `git push/rebase/merge/cherry-pick/am/commit`, or `gh pr merge/create`; an interrupted
  `scripts/pr` checkout once left a zero-byte file on a PR. `--force` overrides.
- **Capacity fallback.** `Rate limit reached for …`, `Selected model is at capacity`, or
  `overloaded` switches between Sol 6.1 and Astra 6 (both Fast); when
  both are limited it sleeps 180 s, then 360, 540, 720 s between rounds.
  A transport death (`stream disconnected`, exhausted reconnects) retries the same model after 30 s.
  Retries send a short "continue" message; the follow-up is already in the session.
- **Classified exits, no blind retries.** 0 finished; 1 gave up or unclassified failure (read the
  log); 2 usage error, including codex rejecting the resume flags; 3 not resumable (missing
  session, `list_turns is not supported`): relaunch fresh with a self-contained order; 4 live
  (open rollout, or codex's `already has an active writer`); 5 stop refused or failed.
- **Per-attempt logs** (`resume-<utc>-p<pid>-<n>.log` beside `-o`), with the "failed to record rollout
  items" flood filtered out before classification.

Wrapper rules live in SKILL.md ("Wrapper and process hygiene"). "Close and resume" loses
nothing: the session keeps full context across model switches and restarts.

For follow-up fixes, resume from the repo directory with the same model, reasoning, and Fast-service overrides:

```bash
(cd <repo> && command codex exec resume <session-id> \
  --dangerously-bypass-approvals-and-sandbox \
  -m gpt-6.1-sol -c 'model_reasoning_effort="high"' \
  --enable fast_mode -c 'service_tier="fast"' \
  -o /tmp/codex-last.md - <"$P2" 2>/dev/null)
```

### How resume works (verified on codex-cli 0.153.4)

`codex exec resume` is a different subcommand with a different flag set than
`codex exec`; the fresh-launch flags do not all carry over.

- **No `-C`.** `resume` has no directory flag; the working directory *is* the
  repo selector. Always wrap it in `(cd <repo> && …)`. Passing `-C` fails with
  `error: unexpected argument '-C' found` — and because the launcher line usually
  ends in `echo "exit=$?"` or a log redirect, the harness chip can still report
  exit 0. After every resume, check the log tail for `Usage: codex exec resume`
  before trusting the completion notification; if it is there, nothing ran.
- **No `--yolo`.** Use `--dangerously-bypass-approvals-and-sandbox` (accepted on
  resume). `--skip-git-repo-check`, `-m`, `-c`, `--enable`, `-o`, `--json`,
  `--output-schema`, `--ephemeral` are accepted; `--full-auto` and `-C` are not.
- **Session selection.** Positional `[SESSION_ID]` takes a UUID (from the
  `session id:` line in the fresh run's log) or a thread name. `--last` picks the
  newest session recorded *for this cwd* (cwd-filtered; `--all` disables the
  filter). With parallel workers on the machine, always pass the explicit UUID.
- **Prompt.** Positional `[PROMPT]`, or `-` to read it from stdin; keep using
  the temp-file pattern (`- <"$P2"`). The resumed worker keeps its full prior
  context, so the follow-up prompt should state only the delta: the decision,
  the amended constraint, what still stands, and the required report.
- **Overrides are per launch.** Model, reasoning effort, service tier, and
  `-o` are not remembered; re-pass all of them. The recorded provider and
  sandbox policy are inherited from the original session.
- **Resume can be refused for a long thread.** `Error: thread/resume: thread/resume
  failed: list_turns is not supported yet (code -32601)` means the backend cannot
  rehydrate that session (seen after ~400k tokens of tool output). The command
  exits non-zero after printing the *previous* run's final message, so it looks
  like a no-op. Do not retry; relaunch as a fresh `codex exec` with a
  self-contained order (state the branch/PR/worktree explicitly, since the new
  session has no memory of them).
- **Escape-hatch stops resume cleanly.** A worker that stopped under a spec's
  escape hatch is not saturated; resuming it with the coordinator's decision is
  the intended flow and cheaper than a fresh order. Only start a fresh session
  for a genuinely new work order.

## Liveness watchdog (long monitored runs)

For runs you must not babysit, trade the stderr suppression for a log and watch its mtime; read only the `-o` file into context, never the log body.

```bash
command codex exec --yolo -C <repo> \
  -m gpt-6.1-sol -c 'model_reasoning_effort="high"' \
  --enable fast_mode -c 'service_tier="fast"' \
  -o "$OUT" - <"$P" > "$LOG" 2>&1
# Claude Code: run the line above as its own Bash run_in_background call
# (tracked chip + completion notification). Append `&` + a PID file ONLY in
# environments without tracked backgrounding.
```

- Capture the session id immediately: `grep -m1 "session id:" "$LOG"`. `resume --last` is cwd-filtered but races with any parallel Codex on the machine — with the id saved, recovery is deterministic.
- Watchdog loop (Claude Code: `Monitor` tool; else a bg shell): every 60s, if the codex process is alive but `$LOG` mtime is older than ~300s, treat it as hung. Because stderr (thinking stream) is in the log, mtime stays fresh during long reasoning — 5 min of true silence is a real hang, not thinking.
- Recovery: `codex-resume --stop -o "$OUT" <session-id>` stops the hung worker and resumes the SAME session (no context lost).

- Exit watchdog silently when the process ends normally (the run's own completion signal covers it); emit only on staleness.
- Verified on codex-cli 0.144.4: `codex exec resume [SESSION_ID] [PROMPT]`, `--last`, cwd-filtering, `--all`.
