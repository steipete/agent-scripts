# AGENTS.MD

Jacob owns this. Start: say hi + 1 motivating line.
Work style: telegraph; noun-phrases ok; drop grammar; min tokens.

## Agent Protocol

- Contact: Jacob Nilsson (@jacobjnilsson, <jacobjnilsson@gmail.com>).
- Workspace: `~/Developer/jacobjnilsson`. Missing steipete repo: clone `https://github.com/jacobjnilsson/<repo>.git`.
- 3rd-party/OSS (non-steipete): clone under `~/Projects/oss`.
- `~/Developer/jacobjnilsson/manager`: private ops (domains/DNS, redirects/workers, runbooks).
- “MacBook” / “Mac Studio” => SSH there; find hosts/IPs via `tailscale status`.
- Files: repo or `~/Developer/jacobjnilsson/agent-scripts`.
- PRs: use `gh pr view/diff` (no URLs).
- “Make a note” => edit AGENTS.md (shortcut; not a blocker). Ignore `CLAUDE.md`.
- No `./runner`. Guardrails: use `trash` for deletes.
- Need upstream file: stage in `/tmp/`, then cherry-pick; never overwrite tracked.
- Bugs: add regression test when it fits.
- Keep files <~500 LOC; split/refactor as needed.
- Commits: Conventional Commits (`feat|fix|refactor|build|ci|chore|docs|style|perf|test`).
- Subagents: read `docs/subagent.md`.
- Editor: `code <path>`.
- CI: `gh run list/view` (rerun/fix til green).
- Prefer end-to-end verify; if blocked, say what’s missing.
- New deps: quick health check (recent releases/commits, adoption).
- Slash cmds: `~/.codex/prompts/`.
- Web: search early; quote exact errors; prefer 2024–2025 sources; fallback Firecrawl (`pnpm mcp:*`) / `mcporter`.
- Oracle: run `npx -y @steipete/oracle --help` once/session before first use.
- Style: telegraph. Drop filler/grammar. Min tokens (global AGENTS + replies).

## Screenshots (“use a screenshot”)

- Pick newest PNG in `~/Desktop` or `~/Downloads`.
- Verify it’s the right UI (ignore filename).
- Size: `sips -g pixelWidth -g pixelHeight <file>` (prefer 2×).
- Optimize: `imageoptim <file>` (install: `brew install imageoptim-cli`).
- Replace asset; keep dimensions; commit; run gate; verify CI.

## Important Locations

- Blog repo: `~/Projects/steipete.me`
- Notes/Runbooks: `~/Projects/manager/docs/` (e.g. `mac-studio.md`, `mac-vm.md`)
- OpenAI/Codex limits tracking: `~/Documents/steipete/codex limits.md`
- Sparkle keys: `~/Library/CloudStorage/Dropbox/Backup/Sparkle`

## Docs

- Start: run docs list (`docs:list` script, or `bin/docs-list` here if present; ignore if not installed); open docs before coding.
- Follow links until domain makes sense; honor `Read when` hints.
- Keep notes short; update docs when behavior/API changes (no ship w/o docs).
- Add `read_when` hints on cross-cutting docs.
- Model note (2025-11-23): no `gpt-5.1-pro` / `grok-4.1` on Peter’s keys yet.
- Model preference: latest only. OK: Anthropic Opus 4.5 / Sonnet 4.5 (Sonnet 3.5 = old; avoid), OpenAI GPT-5.2, xAI Grok-4.1 Fast, Google Gemini 3 Flash.

## PR Feedback

- Active PR: `gh pr view --json number,title,url --jq '"PR #\\(.number): \\(.title)\\n\\(.url)"'`.
- PR comments: `gh pr view …` + `gh api …/comments --paginate`.
- Replies: cite fix + file/line; resolve threads only after fix lands.
- When merging a PR: thank the contributor in `CHANGELOG.md`.

## Flow & Runtime

- Use repo’s package manager/runtime; no swaps w/o approval.
- Use Codex background for long jobs; tmux only for interactive/persistent (debugger/server).

## Build / Test

- Before handoff: run full gate (lint/typecheck/tests/docs).
- CI red: `gh run list/view`, rerun, fix, push, repeat til green.
- Keep it observable (logs, panes, tails, MCP/browser tools).
- Release: read `docs/RELEASING.md` (or find best checklist if missing).
- Reminder: check `~/.profile` for missing env keys (e.g. `SPARKLE_PRIVATE_KEY_FILE`); Sparkle keys live in `~/Library/CloudStorage/Dropbox/Backup/Sparkle`.

## Git

- Safe by default: `git status/diff/log`. Push only when user asks.
- `git checkout` ok for PR review / explicit request.
- Branch changes require user consent.
- Destructive ops forbidden unless explicit (`reset --hard`, `clean`, `restore`, `rm`, …).
- Remotes under `~/Projects`: prefer HTTPS; flip SSH->HTTPS before pull/push.
- Commit helper on PATH: `committer` (bash). Prefer it; if repo has `./scripts/committer`, use that.
- Don’t delete/rename unexpected stuff; stop + ask.
- No repo-wide S/R scripts; keep edits small/reviewable.
- Avoid manual `git stash`; if Git auto-stashes during pull/rebase, that’s fine (hint, not hard guardrail).
- If user types a command (“pull and push”), that’s consent for that command.
- Use fixup commits if solving issues introduced in commit created in the same pull request.
- Big review: `git --no-pager diff --color=never`.
- Multi-agent: check `git status/diff` before edits; ship small commits.

## Language/Stack Notes

- TypeScript: use repo PM; run `docs:list`; keep files small; follow existing patterns.

## macOS Permissions / Signing (TCC)

- Never re-sign / ad-hoc sign / change bundle ID as “debug” without explicit ok (can mess TCC).

## Critical Thinking

- Fix root cause (not band-aid).
- Unsure: read more code; if still stuck, ask w/ short options.
- Conflicts: call out; pick safer path.
- Unrecognized changes: assume other agent; keep going; focus your changes. If it causes issues, stop + ask user.
- Leave breadcrumb notes in thread.

## Tools

Read `~/Projects/agent-scripts/tools.md` for the full tool catalog if it exists.

### bird

- X CLI: `~/Projects/bird/bird`. Cmds: `tweet`, `reply`, `read`, `thread`, `search`, `mentions`, `whoami`.
- Uses Firefox cookies by default (`--firefox-profile` to switch).

### peekaboo

- Screen tools: `~/Projects/Peekaboo`. Cmds: `capture`, `see`, `click`, `list`, `tools`, `permissions status`.
- Needs Screen Recording + Accessibility. Docs: `~/Projects/Peekaboo/docs/commands/`.

### sweetistics

- X analytics app: `~/Projects/sweetistics`.

### committer

- Commit helper (PATH). Stages only listed paths; required here. Repo may also ship `./scripts/committer`.

### trash

- Move files to Trash: `trash …` (system command).

### bin/docs-list / scripts/docs-list.ts

- Optional. Lists `docs/` + enforces front-matter. Ignore if `bin/docs-list` not installed. Rebuild: `bun build scripts/docs-list.ts --compile --outfile bin/docs-list`.

### bin/browser-tools / scripts/browser-tools.ts

- Chrome DevTools helper. Cmds: `start`, `nav`, `eval`, `screenshot`, `pick`, `cookies`, `inspect`, `kill`.
- Rebuild: `bun build scripts/browser-tools.ts --compile --target bun --outfile bin/browser-tools`.

### xcp

- Xcode project/workspace helper for managing targets, groups, files, build settings, and assets; run `xcp --help`.

### xcodegen

- Generates Xcode projects from YAML specs; run `xcodegen --help`.

### lldb

- Use `lldb` inside tmux to debug native apps; attach to the running app to inspect state.

### axe

- Simulator automation CLI for describing UI (`axe describe-ui --udid …`), tapping (`axe tap --udid … -x … -y …`), typing, and hardware buttons. Use `axe list-simulators` to enumerate devices.

### oracle

- Bundle prompt+files for 2nd model. Use when stuck/buggy/review.
- Run `npx -y @steipete/oracle --help` once/session (before first use).

### mcporter / iterm / firecrawl / XcodeBuildMCP

- MCP launcher: `npx mcporter <server>` (see `npx mcporter --help`). Common: `iterm`, `firecrawl`, `XcodeBuildMCP`.

### gh

- GitHub CLI for PRs/CI/releases. Given issue/PR URL (or `/pull/5`): use `gh`, not web search.
- Examples: `gh issue view <url> --comments -R owner/repo`, `gh pr view <url> --comments --files -R owner/repo`.

### Slash Commands

- Global: `~/.codex/prompts/`. Repo-local: `docs/slash-commands/`.
- Common: `/handoff`, `/pickup`.

### tmux

- Use only when you need persistence/interaction (debugger/server).
- Quick refs: `tmux new -d -s codex-shell`, `tmux attach -t codex-shell`, `tmux list-sessions`, `tmux kill-session -t codex-shell`.

<frontend_aesthetics>
Avoid “AI slop” UI. Be opinionated + distinctive.

Do:

- Typography: pick a real font; avoid Inter/Roboto/Arial/system defaults.
- Theme: commit to a palette; use CSS vars; bold accents > timid gradients.
- Motion: 1–2 high-impact moments (staggered reveal beats random micro-anim).
- Background: add depth (gradients/patterns), not flat default.

Avoid: purple-on-white clichés, generic component grids, predictable layouts.
</frontend_aesthetics>
