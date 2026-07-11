---
summary: Timeline of guardrail helper changes mirrored from Sweetistics and related repos.
---

# Changelog

## 2026-07-11 — Browser Tools Hardening
- Removed shell interpretation from browser profile setup, preserved relative symlinks while copying profiles, and fixed the `--no-serialize` console flag. Thanks @ShiroKSH.

## 2026-07-11 — xurl Install Discovery
- Fixed the xurl skill's npm installer metadata so OpenClaw discovers the supported Node installation path. Thanks @not-stbenjam.

## 2026-07-09 — ClawSweeper Worker Capacity
- Made `clawsweeper-status` report actual Codex job utilization against configured capacity, exact-review queue and target occupancy, and workflow concurrency waiters separately from queued jobs.

## 2026-07-04 — npm Session Cache
- Cached newly created npm registry sessions back to the Molty 1Password item through a verified JSON-only update, eliminating repeated TOTP logins across Macs without exposing the token in arguments or logs.

## 2026-07-04 — Shared Skill Exposure
- Exposed the remaining public `agent-skills` skills (`behavior-validator`, `session-viewer`) as tracked symlinks so the per-machine mirror serves them alongside `crabbox`.

## 2026-07-04 — Crabbox Skill Mirror Exposure
- Exposed the shared `crabbox` skill as a tracked symlink (`skills/crabbox -> ../../agent-skills/skills/crabbox`) so the per-machine mirror serves `$crabbox` again; the link was never added when the skill landed in `agent-skills`, and the 2026-07-04 sync-skills mirror rebuild made the gap user-visible.

## 2026-07-03 — npm Service-Account Auth
- Unified the npm helpers on a shared `npm-auth.sh`: Molty service-account item by default with stored registry-session reuse, hardened `npm-auth-login.mjs` login fallback, explicit `--account` desktop fallback, and a generic `npm-service.sh` wrapper for authenticated npm commands.

## 2026-07-03 — Orchestrator Public Gate
- Made the maintainer-orchestrator public gate forward-looking (never preemptive), moved worker thread titles to root-only mutation with explicit thread ids, and refreshed the non-majority repository snapshot.

## 2026-07-03 — Canonical Test Email
- Fixed the shared test email to `clawdbot@gmail.com`; the previous `gog+` alias never existed.

## 2026-07-03 — Claude Skill Mirror
- Added `scripts/sync-skills`: builds the per-machine skill mirror (Codex whole-root links, flat per-skill Claude links with agent-scripts > manager > codex-local priority, shared `AGENTS.MD` pointers) since Claude Code only scans `~/.claude/skills` one level deep; documented the layout in the README.

## 2026-07-02 — npm Credential Field Safety
- Added a reusable npm publish helper that prefers canonical 1Password field IDs, rejects ambiguous duplicate labels, verifies registry publication, and shares the hardened login path with package reservation.

## 2026-07-02 — UTF-8 Skill Validation
- Made skill validation explicitly read UTF-8 so C locales accept non-ASCII skill front matter. Thanks @chaochaoweb3.

## 2026-07-02 — Orchestrator Ownership
- Kept `maintainer-orchestrator` skill maintenance in the root orchestration session and enforced exactly one Codex app thread per project, removing project-to-task thread fan-out including the OpenClaw exception.

## 2026-07-01 — Isolated Skill Audits
- Added `skill-cleaner --root-only` for auditing only explicitly supplied skill roots without Codex inventory noise. Thanks @its-How.

## 2026-07-01 — OSS Maintainer Orchestration
- Expanded `maintainer-orchestrator` into a long-running control plane with one Codex app worker thread per repository, a 30-thread concurrency target with immediate smallest-queue refill, concrete status-based thread titles, safe repository synchronization, forgotten-work preservation, PR rewrite/deduplication, decision-ready risk and diff summaries, durable `VISION.md` policy capture, dependency audits, release proposals with strongest-first highlights, and a persistent daily log plus heartbeat.
- Added an explicit OpenClaw mode with root-session-only discovery and triage, 30 isolated `OC`-named execution worktrees for already-qualified tasks, adoption of existing lanes, root-only owner questions, Discord-sourced external-contributor discovery, live GitHub permission filtering, Vision-based autonomy, repo-native serialized landing, and OpenClaw-specific proof and changelog rules.
- Made activation create or update a five-minute root-session monitoring heartbeat, raised generic and OpenClaw execution concurrency to 30 qualified lanes, and made answered owner decisions advance immediately to the next prepared question while autonomous work continues.
- Required every implementation and execution worker to be a Codex app thread; restricted collaboration subagents to read-only orchestration support with mandatory pre-spawn classification and preservation-first handoff of any misrouted implementation work.

## 2026-06-27 — Internal Handling Boundary
- Clarified that task-relevant confidential information may be used in authorized internal contexts while external disclosure still requires explicit content and destination approval.

## 2026-06-23 — Remote Mac Network Boundaries
- Updated `remote-mac` discovery to use live Tailscale addresses, honor network-boundary constraints, and avoid stale IPs or unreachable relays.

## 2026-06-22 — Release Gate Scope
- Updated `maintainer-orchestrator` so only target-release work and demonstrated candidate regressions block releases; unrelated open issues and PRs remain backlog without exemption requests.

## 2026-06-19 — Gmail Login Pre-Approval
- Added global guidance that user-owned Gmail service logins may use saved credentials without asking, while persistent access changes remain separately gated.

## 2026-06-19 — ClawSweeper Status Payload Bounds
- Reworked `clawsweeper-status` around field-bounded workflow and PR queries plus small activity windows, avoiding GitHub relay response caps while preserving worker and repository activity reporting.

## 2026-06-16 — Image Upload Guardrail
- Added device-aware image upload guidance that defaults work-managed devices to approved content and destinations only.

## 2026-06-15 — Locked-Mac Git Fallback
- Added AGENTS guidance to use HTTPS transport and unsigned commits when Secretive signing is unavailable on a locked Mac.

## 2026-06-15 — PR Quality Guardrail
- Added global guidance to improve AI-generated PR code before landing and permit complete rewrites when cleaner.

## 2026-06-14 — Skill Budget Audit
- Updated `skill-cleaner` to audit the live Codex skill inventory, aliased paths, prompt budget, and actual usage traces while retaining broad duplicate diagnostics.
- Compacted verbose personal skill descriptions without weakening their routing triggers.

## 2026-06-11 — Confidentiality Guardrail
- Added strong global guidance against exposing non-public organizational information, including internal project and model names.

## 2026-06-11 — Maintainer Decision Briefs
- Updated `maintainer-orchestrator` to refresh state before owner questions and explain each decision with the change, proof, risks, recommendation, and exact choices instead of bare land/delete prompts.

## 2026-06-06 — GitHub Triage Autonomy
- Updated `github-project-triage` so `triage` scans issues and PRs, surfaces autonomous candidates versus Peter-blocked items, treats Peter/owner comments as authoritative, requires independent feasibility checks where available, and posts exact verification proof after every landed PR.

## 2026-06-06 — Chrome Plugin Routing
- Updated `browser-use` to prefer the callable Codex Chrome plugin and fall back to the existing-profile mcporter route when unavailable.

## 2026-05-28 — 1Password Timeout Escalation
- Added AGENTS guidance to use `sag` to call Peter aloud when interactive 1Password unlock/sign-in times out, keeping the tmux session alive for retry.

## 2026-05-26 — Browser Network Capture
- Added `network` to `scripts/browser-tools.ts` for tailing DevTools request, response, and failure events from the active tab, with resource-type filters, color control, one-shot captures, and follow mode. Thanks @mvanhorn.

## 2026-05-25 — Agent Skills Origin
- Added `wrangler` skill for Cloudflare account routing, current Wrangler flags, KV/tail pitfalls, and serial command hygiene.
- Updated `skill-cleaner` to realpath-dedupe roots, keep Dropbox archives opt-in, print Codex-rule GPT-5.5 2% budget usage, scope disabled-plugin parsing correctly, and rank duplicate delete suggestions by body similarity with Codex/system copies preferred.
- Added `skill-cleaner` for auditing loaded Codex/OpenClaw skills, duplicate copies, recent usage, and prompt-budget description candidates.
- Renamed release workflow skills to the `release-*` convention and moved product-specific release skills into their owning repos.
- Added AGENTS guidance that `../agent-skills` means `openclaw/agent-skills`, plus local `handoff` skill routing.

## 2026-05-24 — 1Password Item Lookup
- Updated `one-password` to allow explicit vault-scoped metadata search for fuzzy/screenshot-driven item lookup before exact field reads.

## 2026-05-23 — Skill Description Budget
- Shortened skill frontmatter descriptions to terse trigger phrases so the skills prompt budget keeps useful routing hints without filler prose.
- Updated `gog` auth guidance to preserve broad user OAuth scopes during reauth and rely on command guards for scoped execution.

## 2026-05-22 — Browser UI Verification
- Added hard guidance to verify screenshot/live UI bugs through the existing Chrome `$browser-use` path, including one-shot Peekaboo acceptance for visible Chrome attach alerts and no silent Playwright fallback for login/profile-dependent pages.

## 2026-05-22 — npm Release Auth
- Updated `npm` to treat explicit release/publish requests as consent for the expected desktop 1Password npm auth prompt when service-account access cannot read `npmjs`, while still stopping on missing or ambiguous credentials.

## 2026-05-22 — Auto Review Skill
- Replaced the old `codex-review` skill with `autoreview`, keeping Codex as the default/recommended review engine while adding structured findings, prompt/dataset inputs, tool/web-search review context, and security-aware checks.

## 2026-05-21 — Mac App Release Skill
- Added `release-mac-app` skill and `mac-release` helper so Sparkle appcast, key validation, GitHub release asset checks, and release closeout are shared while app metadata stays in each repo’s `.mac-release.env`.

## 2026-05-20 — Browser Login Automation
- Updated `browser-use` to prefer existing Chrome for login-heavy sites because isolated profiles trigger captcha/device checks.

## 2026-05-20 — OpenClaw Deployment Account
- Added AGENTS routing to require `service@openclaw.org` accounts for OpenClaw deployments.

## 2026-05-20 — Things Todo Skill
- Added `things-todo` skill for Things 3 todo CRUD through the `things` CLI with auth-token handling, JSON/read-back verification, and no direct DB-write guidance.

## 2026-05-20 — Reminders Skill
- Added `reminders` skill for Apple Reminders CRUD through the `rem` CLI with JSON/read-back verification and macOS permission notes.

## 2026-05-20 — GitHub Triage Skill Detail
- Updated `github-project-triage` to summarize each issue/PR with fit, risk, proof, blockers, next action, and contributor trust signals.
- Added a bundled `github-activity.sh` helper for repo/global GitHub author activity checks during triage.

## 2026-05-20 — Codex Review Autoreview Trigger
- Updated `codex-review` skill description to include `autoreview` for routing/search.

## 2026-05-18 — 1Password Exact Field Reads
- Updated `one-password` to avoid tmux window-index assumptions and document exact-label JSON extraction when `op --field` resolves an ambiguous concealed field.

## 2026-05-18 — SSH Doctor Skill
- Added `ssh-doctor` for Remote Login diagnosis, launchd sshd pre-auth closes, stale `sshd-session` cleanup, and safe OP profile token block checks.

## 2026-05-18 — 1Password Service Account Priority
- Updated `one-password` to prefer scoped service-account access before interactive desktop-app sign-in and to ask before fallback when scoped access is missing.

## 2026-05-18 — Browser Reattach Defaults
- Updated `browser-use` to call the default mcporter `chrome-devtools` reattach target without a temporary config file.
- Added browser-use mcporter config notes for diagnosing blank/isolated Chrome attachments and restoring the reattach config.

## 2026-05-18 — Lean Fix Guidance
- Added AGENTS guidance to prefer clean bounded refactors over tiny shims and avoid compat/edge-case scaffolding except for real public/API, upgrade, security, or production states.

## 2026-05-16 — Codex Review Gitcrawl Repair
- Extended `codex-review` Gitcrawl recovery guidance to inspect portable manifest, source/runtime DB health, and portable-store status before live fallback.
- Updated `codex-review` to run `gitcrawl doctor --json` for malformed local Gitcrawl DB errors before falling back to live GitHub reads.

## 2026-05-16 — GitHub Project Triage Scope
- Updated `github-project-triage` to default broad queue scans to `steipete` and `openclaw`, sort PR triage by PR count, and preserve RepoBar order when summarizing.

## 2026-05-14 — Video Transcript Dependency Update
- Updated `video-transcript-downloader` to `youtube-transcript-plus` 2.0.0.

## 2026-05-14 — Codex Review Finding Detection
- Updated `codex-review` to capture review output, report elapsed time, fail on reported P0-P3 findings, and treat empty review output as non-clean.

## 2026-05-14 — Codex Review Full Access
- Added `codex-review --full-access` for nested review runs that need localhost bind/listen tests without sandbox noise.

## 2026-05-14 — GitHub Search Shim Guidance
- Added AGENTS guidance to prefer shimmed `gh` / `gitcrawl gh` for broad reads and avoid raw Search API POST mistakes.

## 2026-05-14 — Codex Review Base Caveat
- Documented that `codex review --base` must not include an inline prompt; use a separate follow-up pass for custom instructions.
- Clarified that committed or PR branch review must use branch/base mode, not `--uncommitted` / local mode.

## 2026-05-14 — Codex Review Loop Guidance
- Clarified that `codex-review` should iterate until no accepted findings remain and document intentional rejections with useful inline comments when warranted.

## 2026-05-14 — README Skills Overview
- Rewrote the README around agent instructions, skills, helper scripts, and sync expectations; removed stale copied-origin notes.

## 2026-05-14 — Codex Review Skill
- Added a `codex-review` skill and helper for closeout reviews, with stdout-only default output and subagent filtering guidance for noisy review output.

## 2026-05-13 — Checkout Discipline
- Added CLI checkout/worktree guardrails: stay in repo cwd by default, never create worktrees unless asked, and treat sibling checkouts under `~/Projects` as user-managed.

## 2026-05-13 — Skill Metadata Guardrails
- Added generic skill-description guidance and quieter browser recovery notes to reduce noisy auth prompts and token-heavy skill metadata.

## 2026-05-11 — clawmac GUI Access Note
- Documented the Peekaboo through Jump Desktop workflow for clawmac GUI prompts and Chrome Safe Storage verification.
- Documented `crabmac` as Peter's typo/alias for `clawmac`.

## 2025-12-22 — Remove Custom rm Shim
- Dropped `bin/rm` and `scripts/trash.ts`; rely on the system `trash` command for recoverable deletes.

## 2025-12-17 — Remove Runner; Keep Guardrails
- Removed the `runner` wrapper and `scripts/runner.ts` now that modern Codex sessions handle long-running/background work directly.
- Kept the safety-critical bits as standalone shims: `bin/rm` (moves deletes to Trash via `scripts/trash.ts`).
- Dropped the `find -delete` interception and the `bin/sleep` shim.

## 2025-12-02 — Release Preflight Helpers
- Added shared release helpers in `release/sparkle_lib.sh`: clean working-tree check, Sparkle key probe, changelog finalization/notes extraction, and appcast monotonicity guard for version/build.
- Documented the helper functions in `docs/RELEASING-MAC.md` so Trimmy/CodexBar-style release scripts can reuse them.

## 2025-11-18 — Console Log Capture
- Added `console` command to `scripts/browser-tools.ts` for capturing and monitoring Chrome DevTools console output with real-time formatting, type filtering (log, error, warn, etc.), continuous follow mode, and configurable timeouts with automatic object serialization.

## 2025-11-22 — Search & Content Extraction
- Added `search` and `content` commands to `scripts/browser-tools.ts` for Google SERP scraping with optional readable markdown extraction and single-URL readability output, leveraging the existing DevTools-connected Chrome instance.
- `eval` now supports `--pretty-print` to inspect complex objects with indentation and colors.

## 2025-11-15 — Chrome Browser Tools
- Added `scripts/browser-tools.ts`, a DevTools-ready Chrome helper copied from the Oracle repo so agents can inspect, screenshot, and terminate sessions without dragging in the full CLI. The workflow is inspired by Mario Zechner’s [“What if you don’t need MCP?”](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/).
- Documented the new helper in the README so downstream repos know how to run `pnpm tsx scripts/browser-tools.ts --help`.

## 2025-11-16 — Browser Tools Pipe Detection
- Updated `scripts/browser-tools.ts` to enumerate and kill Chrome instances started with `--remote-debugging-pipe` (the default for Peekaboo/Tachikoma) in addition to the classic `--remote-debugging-port`. List/kill now show “debugging pipe” when no port exists and still fetch tab metadata when it does.
- README now notes the optional `NODE_PATH=$(npm root -g)` trick so the helper can run from bare copies of the repo without a local `package.json`.

## 2025-11-14 — Compact Runner Summaries
- The runner's completion log now defaults to a compact `exit <code> in <time>` format so long commands don't repeat the entire input line.
- Added the `RUNNER_SUMMARY_STYLE` env var with `compact` (default), `minimal`, and `verbose` options so agents can pick how much detail they want without editing the script.
- Timeout heuristics now understand both `pnpm` and `bun` invocations automatically, so long-running Bun scripts/tests get the same guardrails without repo-specific patches.
- `sleep` invocations longer than 30 seconds are clamped to the 30s ceiling instead of erroring, which keeps wait hacks working while still honoring the AGENTS.MD limit.

## 2025-11-08 — Sleep Guardrail & Git Shim Refresh
- Runner now rejects any `sleep` argument longer than 30 seconds, mirroring the AGENTS rule and preventing long blocking waits.
- Added `bin/sleep` so plain `sleep` calls automatically route through the runner and inherit the enforcement without extra flags.
- Simplified `bin/git` to delegate directly to the runner + system git, eliminating the bespoke policy checker while keeping consent gates identical.

## 2025-11-08 — Guardrail Sync & Docs Hardening
- Synced guardrail helpers with Sweetistics so downstream repos share the same runner, docs-list helper, and supporting scripts.
- Expanded README guidance around runner usage, portability, and multi-repo sync expectations.
- Added committer lock cleanup, tightened path ignores, and refreshed misc. helper utilities (e.g., `toArray`) to reduce drift across repos.

## 2025-11-08 — Initial Toolkit Import
- Established the repo with the Sweetistics guardrail toolkit (runner, git policy enforcement, docs-list helper, etc.).
- Ported documentation from the main product repo so other projects inherit the identical safety rails and onboarding notes.
